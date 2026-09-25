import SwiftUI
import MarkdownUI

struct MessageRow: View {
    let message: ChatMessage
    var streaming = false
    var copy: (String) -> Void
    var open: (MessageAction, String?) -> Void
    var useAsDraft: (String) -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.isUser { Spacer(minLength: 44) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 8) {
                if message.isUser {
                    Text(message.displayText)
                        .font(.system(size: 17)).lineSpacing(5).textSelection(.enabled)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(Color(red: 0.93, green: 0.92, blue: 0.96),
                                    in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                } else {
                    assistantContent
                }
                if !message.isUser {
                HStack(spacing: 14) {
                    Text(message.createdAt, style: .time).font(.system(size: 11)).foregroundStyle(.secondary)
                    if !streaming && message.interim.isEmpty {
                        Button {
                            copy(message.displayText)
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .frame(minWidth: 28, minHeight: 32)
                        }.accessibilityLabel(copied ? "Message copied" : "Copy message")
                        ShareLink(item: message.displayText) {
                            Image(systemName: "square.and.arrow.up").frame(minWidth: 28, minHeight: 32)
                        }.accessibilityLabel("Share message")
                    } else {
                        Text(message.isUser ? "Transcribing…" : "Writing…").font(.system(size: 10))
                    }
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .contextMenu {
                if !message.isUser {
                Button("Copy", systemImage: "doc.on.doc") { copy(message.displayText) }
                ShareLink(item: message.displayText) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                if message.isUser {
                    Button("Use as draft", systemImage: "square.and.pencil") { useAsDraft(message.displayText) }
                }
            }
            if !message.isUser { Spacer(minLength: 12) }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }

    private var assistantContent: some View {
        let content = MessageContent(message.text)
        return VStack(alignment: .leading, spacing: 12) {
            Markdown(content.markdown)
                .markdownTextStyle(\.text) {
                    BackgroundColor(.clear)
                    FontSize(17)
                    ForegroundColor(Color(red: 0.16, green: 0.16, blue: 0.20))
                }
                .markdownBlockStyle(\.codeBlock) { configuration in
                    CopyableCodeBlock(language: configuration.language, content: configuration.content,
                                      streaming: streaming, copy: copy)
                }
                .markdownBlockStyle(\.table) { configuration in
                    ScrollView(.horizontal) { configuration.label }
                        .markdownMargin(top: 8, bottom: 16)
                }
                .textSelection(.enabled)
                .tint(.indigo)
                .markdownTheme(.gitHub)
            if !content.actions.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actionButtons(content) }
                    VStack(alignment: .leading, spacing: 8) { actionButtons(content) }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButtons(_ content: MessageContent) -> some View {
        ForEach(content.actions) { action in
            Button { open(action, content.prompt) } label: {
                Label(action.title, systemImage: "arrow.up.right")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 15).padding(.vertical, 12)
                    .background(Color.indigo.opacity(0.07), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.indigo.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .disabled(streaming)
            .accessibilityHint(content.prompt == nil ? "Opens the installed app" : "Copies the prompt and opens the installed app")
        }
    }
}

private struct CopyableCodeBlock: View {
    let language: String?
    let content: String
    let streaming: Bool
    let copy: (String) -> Void
    @State private var copied = false

    private var isPrompt: Bool { ["", "text", "plaintext", "prompt"].contains((language ?? "").lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isPrompt ? "TEXT" : (language ?? "code").uppercased())
                    .font(.system(size: 9, weight: .semibold)).tracking(1.1)
                Spacer()
                Button {
                    copy(content)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : (isPrompt ? "Copy text" : "Copy code"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium)).frame(minHeight: 36)
                }.buttonStyle(.plain).disabled(streaming)
            }
            .padding(.horizontal, 14).padding(.vertical, 3)
            .background(Color.black.opacity(0.04))
            if isPrompt {
                Text(content).font(.system(size: 14, design: .monospaced))
                    .lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            } else {
                ScrollView(.horizontal) {
                    Text(content).font(.system(size: 13, design: .monospaced))
                        .lineSpacing(4).fixedSize(horizontal: true, vertical: false).padding(16)
                }
            }
        }
        .textSelection(.enabled)
        .background(Color(red: 0.95, green: 0.945, blue: 0.965))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.black.opacity(0.06)))
        .markdownMargin(top: 4, bottom: 12)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }
}
