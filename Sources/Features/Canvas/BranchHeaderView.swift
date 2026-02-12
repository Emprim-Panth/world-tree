import SwiftUI

struct BranchHeaderView: View {
    let branch: Branch
    let branchPath: [Branch]
    let siblings: [Branch]
    let onNavigateToBranch: (String) -> Void
    let onComplete: () -> Void

    @State private var isEditingTitle = false
    @State private var editableTitle: String = ""

    var body: some View {
        HStack(spacing: 12) {
            // Branch type icon
            branchTypeIcon
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
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

                // Breadcrumb trail
                HStack(spacing: 4) {
                    breadcrumbTrail

                    Spacer()

                    // Sibling switcher
                    if !siblings.isEmpty {
                        siblingNavigation
                    }
                }

                // Metadata row
                HStack(spacing: 8) {
                    StatusBadge(status: branch.status)

                    if let model = branch.model {
                        ModelBadge(model: model)
                    }

                    Text(branch.createdAt, style: .relative)
                        .font(.caption2)
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

    // MARK: - Breadcrumb Trail

    private var breadcrumbTrail: some View {
        HStack(spacing: 2) {
            ForEach(Array(branchPath.enumerated()), id: \.element.id) { index, ancestor in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if ancestor.id == branch.id {
                    // Current branch — bold, not clickable
                    Text(shortTitle(for: ancestor))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                } else {
                    // Ancestor — clickable
                    Button {
                        onNavigateToBranch(ancestor.id)
                    } label: {
                        Text(shortTitle(for: ancestor))
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Sibling Navigation

    private var siblingNavigation: some View {
        let allSiblings = siblings + [branch]
        let sorted = allSiblings.sorted { $0.createdAt < $1.createdAt }
        let currentIndex = sorted.firstIndex(where: { $0.id == branch.id }) ?? 0
        let total = sorted.count

        return HStack(spacing: 4) {
            Button {
                if currentIndex > 0 {
                    onNavigateToBranch(sorted[currentIndex - 1].id)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex == 0)

            Text("\(currentIndex + 1)/\(total)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                if currentIndex < total - 1 {
                    onNavigateToBranch(sorted[currentIndex + 1].id)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex >= total - 1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary)
        .cornerRadius(4)
    }

    // MARK: - Helpers

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

    private func shortTitle(for branch: Branch) -> String {
        if let title = branch.title, !title.isEmpty {
            return String(title.prefix(25))
        }
        return branch.branchType.rawValue.capitalized
    }

    private func commitTitle() {
        isEditingTitle = false
        let trimmed = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? TreeStore.shared.updateBranch(branch.id, title: trimmed)
    }
}
