import SwiftUI

/// Individual branch column in side-by-side layout
struct BranchColumn: View {
    let branch: Branch
    let width: CGFloat
    let isSelected: Bool
    let onCreateBranch: (UUID) -> Void
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onComplete: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Branch header
            BranchHeader(
                branch: branch,
                isSelected: isSelected,
                onRename: onRename,
                onComplete: onComplete,
                onArchive: onArchive,
                onDelete: onDelete
            )
            .onTapGesture {
                onSelect()
            }

            Divider()

            // Document view for this branch
            if let sessionId = branch.sessionId {
                DocumentEditorView(
                    sessionId: sessionId,
                    branchId: branch.id,
                    workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path + "/Development",
                    parentBranchLayout: nil
                )
                .frame(maxHeight: .infinity)
            } else {
                Text("No active session")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
        .shadow(
            color: isSelected ? .blue.opacity(0.3) : .black.opacity(0.1),
            radius: isSelected ? 8 : 4
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
    }
}

struct BranchHeader: View {
    let branch: Branch
    let isSelected: Bool
    let onRename: (String) -> Void
    let onComplete: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var editedTitle: String

    init(branch: Branch, isSelected: Bool,
         onRename: @escaping (String) -> Void,
         onComplete: @escaping () -> Void,
         onArchive: @escaping () -> Void,
         onDelete: @escaping () -> Void) {
        self.branch = branch
        self.isSelected = isSelected
        self.onRename = onRename
        self.onComplete = onComplete
        self.onArchive = onArchive
        self.onDelete = onDelete
        _editedTitle = State(initialValue: branch.displayTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Branch icon with depth indicator
                HStack(spacing: 4) {
                    ForEach(0..<branch.depth, id: \.self) { _ in
                        Image(systemName: "arrow.turn.up.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 14))
                        .foregroundColor(statusColor)
                }

                // Branch title
                if isEditing {
                    TextField("Branch name", text: $editedTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            onRename(editedTitle)
                            isEditing = false
                        }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(branch.displayTitle)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if let summary = branch.summary {
                            Text(summary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .onTapGesture(count: 2) {
                        isEditing = true
                    }
                }

                Spacer()

                // Branch actions
                Menu {
                    Button("Rename", action: { isEditing = true })
                    Button("Complete", action: onComplete)
                    Button("Archive", action: onArchive)
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
            }

            // Branch metadata
            HStack(spacing: 12) {
                Label("\(branch.messageCount) messages", systemImage: "bubble.left")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Label(branch.status.rawValue.capitalized, systemImage: statusIcon)
                    .font(.caption)
                    .foregroundColor(statusColor)

                Spacer()

                Text(branch.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
    }

    private var statusIcon: String {
        switch branch.status {
        case .active: return "circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .archived: return "archivebox.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch branch.status {
        case .active: return .green
        case .completed: return .blue
        case .archived: return .gray
        case .failed: return .red
        }
    }
}
