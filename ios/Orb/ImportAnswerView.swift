import SwiftUI

struct ImportAnswerView: View {
    @ObservedObject var session: ChatSession
    @Binding var source: MessageAction
    @Binding var answer: String
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Bring your context back").font(.title2.weight(.semibold))
                Text("Copy the answer in ChatGPT or Claude, then paste it here. We’ll save the original and summarize it in the background. You can keep talking; the gist will appear in chat when it’s ready.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Picker("Answer from", selection: $source) {
                    ForEach(MessageAction.allCases) { action in Text(action.appName).tag(action) }
                }.pickerStyle(.segmented)
                ZStack(alignment: .topLeading) {
                    if answer.isEmpty {
                        Text("Paste the answer here…").foregroundStyle(.secondary).padding(.top, 12).padding(.leading, 8)
                    }
                    TextEditor(text: $answer).scrollContentBackground(.hidden)
                        .accessibilityLabel("Answer to import")
                }
                .padding(8).frame(height: 280)
                .background(Color.gray.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                .disabled(session.importing)
                HStack {
                    PasteButton(payloadType: String.self) { strings in answer = strings.joined(separator: "\n") }
                        .labelStyle(.titleAndIcon).disabled(session.importing)
                    Spacer()
                    Text("\(answer.count.formatted()) / 60,000").font(.caption).foregroundStyle(.secondary)
                }
                if let job = session.contextImport {
                    Text("Your \(job.appName) import is already saved. Return to chat to check its progress.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }.padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Button {
                    error = nil
                    Task {
                        do {
                            try await session.importAnswer(answer, source: source)
                            answer = ""
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if session.importing { ProgressView().tint(.white) }
                        Text(session.importing ? "Saving…" : "Save context")
                        Spacer()
                    }.padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).tint(.indigo)
                    .disabled(session.importing || session.contextImport != nil || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || answer.count > 60000)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(.regularMaterial)
            }
            .navigationTitle("Import answer").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(session.importing) } }
            .interactiveDismissDisabled(session.importing)
        }
    }
}
