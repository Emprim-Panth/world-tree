import SwiftUI

struct NewTreeSheet: View {
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Conversation name", text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { submit() }
                } footer: {
                    Text("A new conversation tree will be created on your World Tree server.")
                }
            }
            .navigationTitle("New Tree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { submit() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await connectionManager.send(.createTree(name: trimmed)) }
        dismiss()
    }
}
