import SwiftUI
import AVFoundation

struct ChatView: View {
    var autoConnect = true
    @StateObject private var session = ChatSession()
    @StateObject private var pip = OrbPictureInPicture()
    @State private var showImport = false
    @State private var importSource: MessageAction = .chatGPT
    @State private var importDraft = ""
    @State private var handoffPending = false
    @State private var leftForHandoff = false
    @State private var openingApp = false
    @State private var formed = false
    @State private var settled = false
    @State private var draft = ""
    @State private var settings = false
    @State private var confirmNewChat = false
    @State private var toast: String?
    @State private var followLatest = true
    @State private var bottomVisible = true
    @State private var showSearch = false
    @State private var selectedMessage: UUID?
    @FocusState private var typing: Bool
    @Namespace private var orb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let ink = Color(red: 0.16, green: 0.16, blue: 0.20)
    private let paper = Color(red: 0.985, green: 0.98, blue: 0.97)

    var body: some View {
        ZStack {
            paper.ignoresSafeArea()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--pip-preview") { OrbCallPreview().zIndex(10).frame(maxWidth: .infinity, maxHeight: .infinity).background(paper) }
            #endif
            if settled {
                VStack(spacing: 0) {
                    header
                    importProgress
                    explorationProgress
                    conversation
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { controls }
                .transition(.opacity)
            } else {
                OrbView(formed: formed)
                    .matchedGeometryEffect(id: "orb", in: orb)
                    .frame(width: 112, height: 112)
            }
        }
        .foregroundStyle(ink)
        .preferredColorScheme(.light)
        .task {
            guard !settled else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 1.2, dampingFraction: 0.65)) { formed = true }
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.1 : 1.7))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 1.0, dampingFraction: 0.85)) { settled = true }
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.1 : 0.9))
            guard !Task.isCancelled, autoConnect else { return }
            await session.connect()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await session.resumeAudio() } }
            if phase == .background { leftForHandoff = handoffPending }
            if phase == .active && leftForHandoff {
                leftForHandoff = false
                handoffPending = false
                pip.restore()
                showImport = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { session.audioInterruption($0) }
        .onChange(of: session.connected) { _, connected in pip.setConnected(connected) }
        .onChange(of: session.level) { _, level in pip.level = level }
        .onChange(of: session.isSpeaking) { _, speaking in pip.speaking = speaking }
        .onChange(of: session.muted) { _, muted in pip.muted = muted }
        .sheet(isPresented: $showImport) {
            ImportAnswerView(session: session, source: $importSource, answer: $importDraft)
        }
        .sheet(isPresented: $settings) { settingsView }
        .sheet(isPresented: $showSearch) {
            ChatSearchView(messages: session.messages) { id in
                followLatest = false
                selectedMessage = id
                showSearch = false
            }
        }
        .confirmationDialog("Start a new conversation?", isPresented: $confirmNewChat, titleVisibility: .visible) {
            Button("Start new chat", role: .destructive) {
                draft = ""
                followLatest = true
                Task { await session.newChat() }
            }
        } message: {
            Text("This clears the current chat and starts a fresh voice session. Share it first if you want to keep a copy.")
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast).font(.footnote).padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule()).padding(.top, 62)
                    .allowsHitTesting(false).transition(.opacity)
            }
        }
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { toast = nil }
        }
        .alert("Connection", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
    }

    @ViewBuilder
    private var importProgress: some View {
        if let job = session.contextImport {
            HStack(spacing: 10) {
                if job.status == "failed" { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                else { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.status == "failed" ? "Context saved · summary needs a retry" : "Summarizing context from \(job.appName)…")
                        .font(.system(size: 12, weight: .medium))
                    Text(session.importConnectionIssue ? "Waiting for the server. Your original is saved." : "Keep talking — we’ll add the gist when it’s ready.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if job.status == "failed" {
                    Button("Retry") { session.retryImport() }.font(.caption)
                }
            }
            .padding(12).background(.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 22).padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var explorationProgress: some View {
        if let game = session.exploringGame {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                HStack(spacing: 10) {
                    if session.explorationStatus.hasSuffix("ready") {
                        Image(systemName: "checkmark.circle").foregroundStyle(.indigo)
                    } else { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.explorationStatus).font(.system(size: 12, weight: .medium))
                        Text(game).font(.system(size: 12)).lineLimit(2)
                        Text("30-second demo · keep talking")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let deadline = session.explorationDeadline {
                        Text("\(max(0, Int(ceil(deadline.timeIntervalSince(timeline.date)))))s")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(12).background(.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 22).padding(.bottom, 8)
            }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Circle().fill(session.connected ? Color.green.opacity(0.7) : ink.opacity(0.25)).frame(width: 6, height: 6)
                Text("orb").font(.system(size: 22, weight: .medium, design: .rounded)).tracking(-0.8)
            }
            Spacer()
            Button { showImport = true } label: {
                Image(systemName: "square.and.arrow.down").frame(width: 42, height: 44)
            }.accessibilityLabel("Import answer")
            Menu {
                Button("Float call window", systemImage: "pip.enter") {
                    Task { if !(await pip.start()) { session.error = pip.failure } }
                }.disabled(!session.connected)
                Button("New chat", systemImage: "square.and.pencil") { confirmNewChat = true }
                Button("Search conversation", systemImage: "magnifyingglass") { selectedMessage = nil; showSearch = true }
                    .disabled(session.messages.isEmpty)
                ShareLink(item: session.shareText) { Label("Share conversation", systemImage: "square.and.arrow.up") }
                    .disabled(session.messages.isEmpty)
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }.accessibilityLabel("Chat options")
            if session.connected || session.connecting {
                Button { Task { await session.disconnect() } } label: {
                    Image(systemName: "stop.circle").font(.system(size: 20, weight: .light)).frame(width: 44, height: 44)
                }.accessibilityLabel("End conversation")
            }
            Button { settings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .regular)).frame(width: 44, height: 44)
            }.accessibilityLabel("Connection settings")
        }
        .padding(.leading, 27).padding(.trailing, 15).padding(.top, 8)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if session.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("A little space\nto think out loud.")
                                .font(.system(size: 36, weight: .regular, design: .serif)).tracking(-1)
                            Text("Speak freely. Or start with a few words.")
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        .padding(.top, 68).padding(.bottom, 24)
                        if !session.connected {
                            Button {
                                Task { await session.connect() }
                            } label: {
                                HStack(spacing: 10) {
                                    Text(session.connecting ? "Connecting…" : "Start a conversation")
                                    if session.connecting { ProgressView().controlSize(.small) }
                                    else { Image(systemName: "arrow.up.right") }
                                }
                                .font(.system(size: 14, weight: .medium))
                                .padding(.vertical, 14).padding(.horizontal, 18)
                                .background(.white.opacity(0.9), in: Capsule())
                                .overlay(Capsule().strokeBorder(ink.opacity(0.08)))
                            }.disabled(session.connecting)
                        }
                    }
                    ForEach(session.messages) { message in
                        MessageRow(message: message,
                                   streaming: session.isGenerating && !message.isUser && message.id == session.assistantMessageID,
                                   copy: copyText, open: openAction,
                                   useAsDraft: { draft = $0; typing = true })
                            .id(message.id)
                    }
                    if session.isGenerating {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text(session.messages.last?.isUser == false ? "Writing…" : "Thinking…").font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            Button("Stop") { session.stopResponse() }.font(.footnote)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ChatBottomPosition.self,
                                                   value: geometry.frame(in: .named("chat-scroll")).maxY)
                        })
                }.padding(.horizontal, 28).padding(.bottom, 20)
            }
            .coordinateSpace(name: "chat-scroll")
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(DragGesture().onChanged { _ in followLatest = false })
            .onPreferenceChange(ChatBottomPosition.self) { bottom in
                bottomVisible = bottom > 0 && bottom <= viewport.size.height + 45
                if bottomVisible { followLatest = true }
            }
            .overlay(alignment: .bottomTrailing) {
                if !bottomVisible && !session.messages.isEmpty {
                    Button { followLatest = true; scroll(proxy) } label: {
                        Image(systemName: "arrow.down").font(.system(size: 16, weight: .medium))
                            .frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
                    }.padding(16).accessibilityLabel("Jump to latest message")
                }
            }
            .onChange(of: session.messages.map(\.displayText)) { _, _ in
                if followLatest { scroll(proxy) }
            }
            .onChange(of: typing) { _, focused in if focused { followLatest = true; scroll(proxy) } }
            .onChange(of: selectedMessage) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                OrbView(level: session.level).matchedGeometryEffect(id: "orb", in: orb).frame(width: 46, height: 46)
                    .overlay { OrbPictureInPictureSource(pip: pip) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.status).font(.system(size: 12, weight: .medium))
                    Text(session.connected ? "Your words, in good company." : "Voice & text, together.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if session.isSpeaking && !session.isGenerating {
                    Button { session.stopResponse() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 13)).frame(width: 40, height: 44)
                    }.accessibilityLabel("Stop response")
                }
                if !session.connected && !session.connecting && !session.messages.isEmpty {
                    Button("Reconnect") { Task { await session.connect() } }.font(.caption)
                }
                Button { Task { await session.toggleMute() } } label: {
                    Image(systemName: session.muted ? "mic.slash" : "mic")
                        .font(.system(size: 18)).frame(width: 46, height: 46)
                        .background(session.muted ? ink.opacity(0.08) : .white.opacity(0.8), in: Circle())
                }
                .disabled(!session.connected)
                .accessibilityLabel(session.muted ? "Unmute microphone" : "Mute microphone")
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Say something, or type it here…", text: $draft, axis: .vertical)
                    .font(.system(size: 15)).lineLimit(1...5).focused($typing)
                    .padding(.vertical, 12).padding(.leading, 6)
                    .accessibilityLabel("Message")
                Button {
                    if session.send(draft) { draft = "" }
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 38, height: 38)
                        .background(canSend ? ink : ink.opacity(0.2), in: Circle())
                }.disabled(!canSend).accessibilityLabel("Send message")
            }
            .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(ink.opacity(0.08)))
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 12)
        .background(paper)
    }

    private var canSend: Bool { session.connected && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func copyText(_ text: String) {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        toast = "Copied to clipboard"
        UIAccessibility.post(notification: .announcement, argument: "Copied to clipboard")
    }

    private func openAction(_ action: MessageAction, prompt: String?) {
        guard !openingApp else { return }
        if let prompt, !prompt.isEmpty { copyText(prompt) }
        importSource = action
        guard UIApplication.shared.canOpenURL(action.nativeURL) else {
            session.error = "\(action.appName) isn’t available to open on this iPhone. Install the app or open it manually. The prompt is copied when supplied; return here and tap Import answer after copying its reply."
            return
        }
        openingApp = true
        Task { @MainActor in
            defer { openingApp = false }
            if session.connected {
                guard await pip.start() else {
                    session.error = pip.failure
                    return
                }
            }
            handoffPending = true
            let opened = await UIApplication.shared.open(action.nativeURL)
            if !opened {
                handoffPending = false
                pip.restore()
                session.error = "Couldn’t open \(action.appName). Open it manually, then return here to import its answer."
            }
        }
    }

    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("Voice server") {
                    TextField("http://localhost:7860", text: $session.serverURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(session.connected || session.connecting)
                    Text("On an iPhone, use your Mac’s local network address. On Simulator, use localhost. API keys stay on the server.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("Your microphone is active only during a connected conversation. Voice stays connected when you switch apps. End the conversation here to stop the microphone. Imported answers are stored on your server; chat messages stay in memory. Pinch the floating call window inward to make it smaller.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } }
        }.presentationDetents([.medium, .large])
    }
}

#Preview { ChatView(autoConnect: false) }

private struct ChatBottomPosition: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChatSearchView: View {
    let messages: [ChatMessage]
    let select: (UUID) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    private var results: [ChatMessage] {
        query.isEmpty ? [] : messages.filter { $0.displayText.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(results) { message in
                Button { select(message.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.displayText).lineLimit(4).foregroundStyle(.primary)
                        if !message.isUser { Text(message.createdAt, style: .time).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                }
            }
            .overlay {
                if !query.isEmpty && results.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, prompt: "Search this conversation")
            .navigationTitle("Search").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
