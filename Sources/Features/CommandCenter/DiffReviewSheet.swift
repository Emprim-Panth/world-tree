import SwiftUI

/// Full-screen sheet wrapper for reviewing a git diff from an agent session.
struct DiffReviewSheet: View {
    let session: AgentSession
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                DiffReviewView(session: session)
                    .padding()
            }
            .navigationTitle("Diff Review")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
