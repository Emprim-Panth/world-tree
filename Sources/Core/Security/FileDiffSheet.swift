import SwiftUI

/// Modal sheet that shows a before/after diff for a pending file write or edit.
/// The user can Accept (write proceeds) or Reject (write is cancelled).
struct FileDiffSheet: View {
    let request: FileDiffRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Review File Change")
                        .font(.headline)
                    Text(request.filePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Spacer()
            }
            .padding()

            Divider()

            // Diff view
            ScrollView {
                DiffView(
                    oldText: request.oldContent,
                    newText: request.newContent,
                    filePath: request.filePath
                )
                .padding()
            }
            .frame(minHeight: 300, maxHeight: 500)

            Divider()

            // Action buttons
            HStack {
                Text(request.oldContent.isEmpty ? "New file" : "Modified file")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Reject") {
                    ApprovalCoordinator.shared.resolveFileDiff(approved: false)
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .foregroundStyle(.red)

                Button("Accept") {
                    ApprovalCoordinator.shared.resolveFileDiff(approved: true)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 600, idealWidth: 750)
    }
}
