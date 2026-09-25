import Foundation

enum MessageAction: String, CaseIterable, Identifiable {
    case chatGPT, claude
    var id: String { rawValue }
    var title: String { self == .chatGPT ? "Open ChatGPT" : "Open Claude" }
    var appName: String { self == .chatGPT ? "ChatGPT" : "Claude" }
    var nativeURL: URL { URL(string: self == .chatGPT ? "chatgpt://" : "claude://")! }
    var destination: URL {
        URL(string: self == .chatGPT ? "https://chatgpt.com/" : "https://claude.ai/")!
    }

    static func from(line: String) -> MessageAction? {
        let line = line.trimmingCharacters(in: .whitespaces)
        return allCases.first { action in
            line == "[\(action.title)](\(action.destination.absoluteString))"
                || line == "[\(action.title)](\(action.destination.absoluteString.dropLast()))"
        }
    }
}

/// Extract only our explicit action links outside code fences. All other Markdown stays intact.
struct MessageContent {
    let markdown: String
    let actions: [MessageAction]
    let prompt: String?
    let suggestedGame: String?

    init(_ source: String) {
        var lines: [String] = []
        var actions: [MessageAction] = []
        var fence: Character?
        var fenceLength = 0
        var language = ""
        var code: [String] = []
        var prompt: String?
        var suggestedGame: String?
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let marker = trimmed.first
            let count = trimmed.prefix { $0 == marker }.count
            if let current = fence {
                if marker == current, count >= fenceLength,
                   trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                    if prompt == nil, ["", "text", "plaintext", "prompt"].contains(language.lowercased()) {
                        prompt = code.joined(separator: "\n")
                    }
                    fence = nil
                } else { code.append(line) }
                lines.append(line)
            } else if (marker == "`" || marker == "~"), count >= 3 {
                fence = marker
                fenceLength = count
                language = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
                code = []
                lines.append(line)
            } else if let action = MessageAction.from(line: line) {
                if !actions.contains(action) { actions.append(action) }
            } else {
                if trimmed.hasPrefix("**Game:** ") {
                    let title = String(trimmed.dropFirst("**Game:** ".count)).trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty { suggestedGame = title }
                }
                lines.append(line)
            }
        }
        markdown = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.actions = actions
        self.prompt = prompt
        self.suggestedGame = suggestedGame
    }
}
