import SwiftUI

struct NewBranchSheet: View {
    let treeId: String
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Branch title (optional)", text: $title)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { submit() }
                } footer: {
                    Text("A new branch will be created in this conversation tree.")
                }
            }
            .navigationTitle("New Branch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { submit() }
                }
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await connectionManager.send(.createBranch(
                treeId: treeId,
                title: trimmed.isEmpty ? nil : trimmed
            ))
        }
        dismiss()
    }
}
