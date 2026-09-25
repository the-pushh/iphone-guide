import AVFoundation
import SwiftUI
import PipecatClientIOS
import PipecatClientIOSSmallWebrtc

@MainActor
final class ChatSession: ObservableObject {
    @Published private var transcript = ConversationTranscript()
    var messages: [ChatMessage] { transcript.messages }
    var assistantMessageID: UUID? { transcript.assistantID }
    @Published var isGenerating = false
    @Published var isSpeaking = false
    private var hasLLMResponse = false
    @Published var status = "Ready when you are"
    @Published var connected = false
    @Published var connecting = false
    @Published var muted = false
    @Published var level: Double = 0
    @Published var error: String?
    @AppStorage("serverURL") var serverURL = "http://localhost:7860"
    @Published var importing = false
    @Published private(set) var contextImport: ContextImport?
    @Published private(set) var importConnectionIssue = false
    private var importPoll: Task<Void, Never>?
    private var importServer: String?

    // A UI experiment only: the main app owns real Game/Quest exploration.
    @Published private(set) var exploringGame: String?
    @Published private(set) var explorationDeadline: Date?
    @Published private(set) var explorationStatus = ""
    private var explorationTask: Task<Void, Never>?
    private var exploredGames: Set<String> = []
    private var awaitingExplorationReply = false
    private var userIsSpeaking = false

    private func exploreSuggestedGame() {
        guard explorationTask == nil,
              let message = messages.first(where: { $0.id == assistantMessageID }),
              let game = MessageContent(message.text).suggestedGame,
              !exploredGames.contains(game.lowercased()) else { return }
        exploredGames.insert(game.lowercased())
        exploringGame = game
        explorationDeadline = Date().addingTimeInterval(30)
        explorationStatus = "Exploring Quests and Moves"
        explorationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.explorationDeadline = nil
            self.explorationStatus = "Exploration delay complete · waiting for a pause"
            // Let the active turn finish before requesting the proposed breakdown.
            while self.isGenerating || self.isSpeaking || self.userIsSpeaking {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
            guard !Task.isCancelled, self.connected else { return }
            do {
                try self.client?.sendClientMessage(msgType: "exploration-ready", data: .string(game))
                self.awaitingExplorationReply = true
                self.explorationStatus = "Preparing Quests and a starting Move…"
            } catch {
                self.explorationStatus = "Couldn’t request the breakdown · ask again in chat"
                self.explorationTask = nil
            }
        }
    }


    private var ownerID: String {
        if let id = UserDefaults.standard.string(forKey: "memoryOwner") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "memoryOwner")
        return id
    }
    private var client: PipecatClient?
    private var events: SessionEvents?
    private var generation = UUID()
    private var readinessTimeout: Task<Void, Never>?

    static var previewMode: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--chat-preview") || ProcessInfo.processInfo.arguments.contains("--pip-preview")
        #else
        return false
        #endif
    }

    init() {
        #if DEBUG
        if Self.previewMode {
            transcript.appendTyped("Give me a prompt I can copy into ChatGPT.")
            transcript.assistantStarted()
            transcript.receiveAssistantToken("""
            Here’s a **ready-to-copy prompt**. Tap **Open ChatGPT** to copy it and open the app.

            ```text
            Summarize what you already know about me: my current priorities, projects, commitments, preferences, and constraints.

            Separate facts I’ve told you from your inferences. Be concise, and leave out anything you’re unsure about.
            ```

            Paste it into the chat and send it.

            [Open ChatGPT](https://chatgpt.com/)
            [Open Claude](https://claude.ai/)
            """)
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: "pendingContextImport"),
           let saved = try? JSONDecoder().decode(SavedContextImport.self, from: data) {
            contextImport = saved.job
            importServer = saved.server
            if saved.job.status == "pending" { pollImport() }
        }
    }

    func connect() async {
        guard !connected, !connecting else { return }
        guard let base = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(base.scheme ?? ""), base.host != nil else {
            error = "Enter a valid server URL in connection settings."
            return
        }
        let attempt = UUID()
        generation = attempt
        connecting = true
        error = nil
        status = "Connecting"
        let permission = await AVAudioApplication.requestRecordPermission()
        guard generation == attempt else { return }
        muted = !permission
        let newClient = PipecatClient(options: .init(
            transport: SmallWebRTCTransport(), enableMic: permission, enableCam: false))
        let newEvents = SessionEvents(session: self, generation: attempt)
        events = newEvents
        newClient.delegate = newEvents
        client = newClient
        readinessTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.generation == attempt, self.connecting else { return }
            self.error = "The bot didn’t become ready. Check the server’s provider settings, then reconnect."
            await self.disconnect()
        }
        do {
            try await newClient.connect(transportParams: SmallWebRTCTransportConnectionParams(
                webrtcRequestParams: APIRequest(endpoint: base.appendingPathComponent("api/offer").appending(queryItems: [URLQueryItem(name: "owner", value: ownerID)]), timeout: 20)))
            // The bot-ready callback, rather than the transport connection, enables the composer.
        } catch {
            guard generation == attempt else { return }
            self.error = "Couldn’t connect. Check the server address and that the voice server is running."
            await disconnect()
        }
    }

    func disconnect() async {
        generation = UUID()
        explorationTask?.cancel()
        explorationTask = nil
        exploringGame = nil
        explorationDeadline = nil
        awaitingExplorationReply = false
        userIsSpeaking = false
        exploredGames.removeAll()
        readinessTimeout?.cancel()
        readinessTimeout = nil
        let previous = client
        previous?.delegate = nil
        client = nil
        events = nil
        connected = false
        connecting = false
        level = 0
        isGenerating = false
        isSpeaking = false
        hasLLMResponse = false
        transcript.endGroup()
        status = "Ready when you are"
        try? await previous?.disconnect()
        previous?.release()
    }

    func resumeAudio() async {
        guard connected, let client else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setActive(true)
            // Respect connected headphones; correct a quiet built-in earpiece route.
            if audio.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }),
               let speaker = client.getAllSpeakers().first(where: { $0.id.id == "speakerphone" }) {
                try await client.updateSpeaker(speakerId: speaker.id)
            }
        } catch {
            self.error = "Voice playback couldn’t resume. Close the other audio app, then reconnect."
        }
    }

    func audioInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended,
              let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
              AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) else { return }
        Task { await resumeAudio() }
    }

    func toggleMute() async {
        guard let client, connected else { return }
        if muted, !(await AVAudioApplication.requestRecordPermission()) {
            error = "Microphone access is off. Enable it in iPhone Settings to speak, or keep typing here."
            return
        }
        do {
            try await client.enableMic(enable: muted)
            muted.toggle()
            status = muted ? "Microphone off · type a message" : "Listening"
        } catch { self.error = "Couldn’t change the microphone. Please reconnect." }
    }

    func send(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connected, let client, !text.isEmpty else { return false }
        do {
            try client.sendText(content: text, options: .init(runImmediately: true, audioResponse: true))
            transcript.appendTyped(text)
            isGenerating = true
            status = "Thinking"
            return true
        } catch {
            self.error = "Your message wasn’t sent. Please reconnect and try again."
            return false
        }
    }

    func stopResponse() {
        guard connected, let client else { return }
        do {
            try client.sendClientMessage(msgType: "stop-response")
            isGenerating = false
            isSpeaking = false
            status = muted ? "Microphone off · type a message" : "Listening"
        } catch { self.error = "Couldn’t stop the response. Please reconnect." }
    }

    func importAnswer(_ text: String, source: MessageAction) async throws {
        guard !importing, contextImport == nil, let base = URL(string: serverURL) else {
            throw NSError(domain: "Import", code: 1, userInfo: [NSLocalizedDescriptionKey: "An import is already being processed. You can keep chatting while it finishes."])
        }
        importing = true
        defer { importing = false }
        var request = URLRequest(url: base.appendingPathComponent("api/import"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["owner": ownerID, "source": source.rawValue, "text": text])
        let job = try await fetchImport(request)
        importServer = serverURL
        contextImport = job
        persistImport()
        if job.status == "ready" { completeImport(job) }
        else if job.status == "pending" {
            // Only the app event enters the conversation. The pasted original stays on the server.
            if connected { try? client?.sendClientMessage(msgType: "import-pending") }
            pollImport()
        }
    }

    func retryImport() {
        guard let job = contextImport, let server = importServer,
              let base = URL(string: server) else { return }
        Task {
            do {
                var request = URLRequest(url: base.appendingPathComponent("api/import/\(job.id)/retry")
                    .appending(queryItems: [URLQueryItem(name: "owner", value: ownerID)]))
                request.httpMethod = "POST"
                contextImport = try await fetchImport(request)
                importConnectionIssue = false
                persistImport()
                pollImport()
            } catch { importConnectionIssue = true }
        }
    }

    private func fetchImport(_ request: URLRequest) async throws -> ContextImport {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            throw NSError(domain: "Import", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn’t reach the import service. Check the server and try again. Your text has been kept."])
        }
        return try JSONDecoder().decode(ContextImport.self, from: data)
    }

    private func persistImport() {
        guard let job = contextImport, let server = importServer else {
            UserDefaults.standard.removeObject(forKey: "pendingContextImport")
            return
        }
        if let data = try? JSONEncoder().encode(SavedContextImport(job: job, server: server)) {
            UserDefaults.standard.set(data, forKey: "pendingContextImport")
        }
    }

    private func pollImport() {
        importPoll?.cancel()
        importPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let job = self.contextImport, let server = self.importServer,
                      let base = URL(string: server) else { return }
                if job.status == "ready" { self.completeImport(job); return }
                if job.status == "failed" { return }
                do {
                    var request = URLRequest(url: base.appendingPathComponent("api/import/\(job.id)")
                        .appending(queryItems: [URLQueryItem(name: "owner", value: self.ownerID)]))
                    request.timeoutInterval = 10
                    let update = try await self.fetchImport(request)
                    guard !Task.isCancelled else { return }
                    self.importConnectionIssue = false
                    self.contextImport = update
                    self.persistImport()
                    if update.status == "ready" { self.completeImport(update); return }
                    if update.status == "failed" { return }
                } catch {
                    if Task.isCancelled { return }
                    self.importConnectionIssue = true
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func completeImport(_ job: ContextImport) {
        transcript.appendImport("Context from **\(job.appName)** is ready. Here’s the gist:\n\n\(job.summary)")
        if connected, importServer == serverURL { try? client?.sendClientMessage(msgType: "refresh-memory") }
        contextImport = nil
        importServer = nil
        importConnectionIssue = false
        persistImport()
    }

    func newChat() async {
        await disconnect()
        transcript = ConversationTranscript()
        await connect()
    }

    var shareText: String {
        messages.map { "\($0.isUser ? "You" : "Assistant") · \($0.createdAt.formatted(date: .abbreviated, time: .shortened))\n\($0.displayText)" }
            .joined(separator: "\n\n")
    }

    fileprivate func receive(_ event: SessionEvent, generation: UUID) {
        guard self.generation == generation else { return }
        switch event {
        case .ready:
            readinessTimeout?.cancel()
            transcript.endGroup()
            hasLLMResponse = false
            isGenerating = false
            connecting = false
            connected = true
            Task { await resumeAudio() }
            status = muted ? "Microphone off · type a message" : "Listening"
            if contextImport?.status == "pending", importServer == serverURL {
                try? client?.sendClientMessage(msgType: "import-pending")
            }
        case .disconnected:
            Task { await disconnect() }
        case .error:
            error = "The voice session encountered an error. Check the server and reconnect."
            Task { await disconnect() }
        case .user(let text, let final):
            transcript.receiveUser(text, final: final, at: ProcessInfo.processInfo.systemUptime)
        case .botText(let text):
            // The initial greeting has no LLM stream. Later TTS text would duplicate the response.
            if !hasLLMResponse { transcript.receiveAssistant(text) }
        case .botToken(let text):
            hasLLMResponse = true
            transcript.receiveAssistantToken(text)
            if !isSpeaking { status = "Writing" }
        case .botEnd:
            isGenerating = false
            if awaitingExplorationReply {
                awaitingExplorationReply = false
                explorationStatus = "Quest and Move suggestions ready"
                explorationTask = nil
            } else {
                exploreSuggestedGame()
            }
            if !isSpeaking { status = muted ? "Microphone off · type a message" : "Listening" }
        case .botStart:
            hasLLMResponse = true
            isGenerating = true
            transcript.assistantStarted()
            status = "Thinking"
        case .speaking(let speaking):
            isSpeaking = speaking
            status = speaking ? "Speaking" : (muted ? "Microphone off · type a message" : "Listening")
            if !speaking { level = 0 }
        case .userSpeaking:
            userIsSpeaking = true
            transcript.userStartedSpeaking(at: ProcessInfo.processInfo.systemUptime)
            status = "Listening to you"
        case .userStoppedSpeaking:
            userIsSpeaking = false
            transcript.userStoppedSpeaking(at: ProcessInfo.processInfo.systemUptime)
        case .level(let value): level = Double(value)
        }
    }
}

private enum SessionEvent: Sendable {
    case ready, disconnected, error, botStart, botEnd, userSpeaking, userStoppedSpeaking
    case user(String, Bool), botText(String), botToken(String), speaking(Bool), level(Float)
}

/// SDK callbacks can arrive off the main thread; all UI mutations are isolated here.
private final class SessionEvents: PipecatClientDelegate {
    private weak var session: ChatSession?
    private let generation: UUID
    init(session: ChatSession, generation: UUID) { self.session = session; self.generation = generation }
    private func emit(_ event: SessionEvent) {
        Task { @MainActor [weak session, generation] in session?.receive(event, generation: generation) }
    }
    func onBotReady(botReadyData: BotReadyData) { emit(.ready) }
    func onDisconnected() { emit(.disconnected) }
    func onBotDisconnected(participant: Participant) { emit(.disconnected) }
    func onError(message: RTVIMessageInbound) { emit(.error) }
    func onMessageError(message: RTVIMessageInbound) { emit(.error) }
    func onUserTranscript(data: Transcript) { emit(.user(data.text, data.final == true)) }
    func onBotLlmStarted() { emit(.botStart) }
    func onBotLlmStopped() { emit(.botEnd) }
    func onBotLlmText(data: BotLLMText) { emit(.botToken(data.text)) }
    func onBotTtsText(data: BotTTSText) { emit(.botText(data.text)) }
    func onBotStartedSpeaking() { emit(.speaking(true)) }
    func onBotStoppedSpeaking() { emit(.speaking(false)) }
    func onUserStartedSpeaking() { emit(.userSpeaking) }
    func onUserStoppedSpeaking() { emit(.userStoppedSpeaking) }
    func onLocalAudioLevel(level: Float) { emit(.level(level)) }
    func onRemoteAudioLevel(level: Float, participant: Participant) { emit(.level(level)) }
}

struct ContextImport: Codable {
    let id: Int
    let source: String
    let status: String
    let summary: String
    var appName: String { source == "claude" ? "Claude" : "ChatGPT" }
}

private struct SavedContextImport: Codable {
    let job: ContextImport
    let server: String
}
