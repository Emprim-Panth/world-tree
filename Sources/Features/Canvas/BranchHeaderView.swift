import SwiftUI

struct BranchHeaderView: View {
    let branch: Branch
    let onNavigateToParent: (() -> Void)?
    let onComplete: () -> Void

    @State private var isEditingTitle = false
    @State private var editableTitle: String = ""

    var body: some View {
        HStack(spacing: 12) {
            // Branch type icon
            branchTypeIcon
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                // Editable title
                if isEditingTitle {
                    TextField("Branch title", text: $editableTitle, onCommit: {
                        commitTitle()
                    })
                    .textFieldStyle(.plain)
                    .font(.headline)
                } else {
                    Text(branch.displayTitle)
                        .font(.headline)
                        .onTapGesture(count: 2) {
                            editableTitle = branch.title ?? ""
                            isEditingTitle = true
                        }
                }

                // Breadcrumb + metadata
                HStack(spacing: 8) {
                    if branch.parentBranchId != nil {
                        Button {
                            onNavigateToParent?()
                        } label: {
                            Label("Parent", systemImage: "arrow.up.left")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }

                    StatusBadge(status: branch.status)

                    if let model = branch.model {
                        ModelBadge(model: model)
                    }

                    Text(branch.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if branch.status == .active {
                Button("Complete") {
                    onComplete()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var branchTypeIcon: some View {
        Group {
            switch branch.branchType {
            case .conversation:
                Image(systemName: "bubble.left.fill")
                    .foregroundStyle(.blue)
            case .implementation:
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.orange)
            case .exploration:
                Image(systemName: "magnifyingglass.circle.fill")
                    .foregroundStyle(.purple)
            }
        }
    }

    private func commitTitle() {
        isEditingTitle = false
        let trimmed = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? TreeStore.shared.updateBranch(branch.id, title: trimmed)
    }
}
