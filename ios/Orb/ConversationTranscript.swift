import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let createdAt = Date()
    let isUser: Bool
    var text: String
    var interim = ""
    var displayText: String { joiningTranscript(text, interim) }
}

/// STT finalizes fragments, not whole thoughts. Keep one bubble until a real pause or reply.
struct ConversationTranscript {
    private(set) var messages: [ChatMessage] = []
    let pauseThreshold: TimeInterval = 2
    private var userID: UUID?
    private(set) var assistantID: UUID?
    private var lastFragmentAt: TimeInterval?
    private var speechStoppedAt: TimeInterval?
    private var hasSpeechEvents = false

    mutating func userStartedSpeaking(at time: TimeInterval) {
        hasSpeechEvents = true
        if let stopped = speechStoppedAt, time - stopped >= pauseThreshold {
            userID = nil
        }
        speechStoppedAt = nil
        assistantID = nil
    }

    mutating func userStoppedSpeaking(at time: TimeInterval) {
        hasSpeechEvents = true
        speechStoppedAt = time
    }

    mutating func receiveUser(_ text: String, final: Bool, at time: TimeInterval) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Fall back to transcript timing for clients that do not emit speech boundaries.
        if !hasSpeechEvents, let previous = lastFragmentAt, time - previous >= pauseThreshold {
            userID = nil
        }
        lastFragmentAt = time
        assistantID = nil
        let index: Int
        if let id = userID, let existing = messages.firstIndex(where: { $0.id == id }) {
            index = existing
        } else {
            let message = ChatMessage(isUser: true, text: "")
            messages.append(message)
            userID = message.id
            index = messages.count - 1
        }
        if final {
            messages[index].text = joiningTranscript(messages[index].text, text)
            messages[index].interim = ""
        } else {
            // Interim hypotheses replace each other; only finalized text is appended.
            messages[index].interim = text
        }
    }

    mutating func appendImport(_ summary: String) {
        messages.append(ChatMessage(isUser: false, text: summary))
    }

    mutating func appendTyped(_ text: String) {
        endGroup()
        messages.append(ChatMessage(isUser: true, text: text))
    }

    mutating func assistantStarted() { assistantID = nil }

    /// LLM tokens carry their own whitespace and Markdown delimiters.
    mutating func receiveAssistantToken(_ text: String) {
        guard !text.isEmpty else { return }
        userID = nil
        if let id = assistantID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += text
        } else {
            let message = ChatMessage(isUser: false, text: text)
            messages.append(message)
            assistantID = message.id
        }
    }

    mutating func receiveAssistant(_ text: String) {
        guard !text.isEmpty else { return }
        userID = nil
        if let id = assistantID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = joiningTranscript(messages[index].text, text)
        } else {
            let message = ChatMessage(isUser: false, text: text)
            messages.append(message)
            assistantID = message.id
        }
    }

    mutating func endGroup() {
        userID = nil
        assistantID = nil
        lastFragmentAt = nil
        speechStoppedAt = nil
        hasSpeechEvents = false
    }
}

private func joiningTranscript(_ first: String, _ second: String) -> String {
    guard !first.isEmpty else { return second }
    guard !second.isEmpty else { return first }
    let needsSpace = first.last?.isWhitespace == false && second.first?.isWhitespace == false
        && second.first.map { !",.!?;:’'".contains($0) } == true
    return first + (needsSpace ? " " : "") + second
}
