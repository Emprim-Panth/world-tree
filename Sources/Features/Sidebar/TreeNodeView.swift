import SwiftUI

/// Recursive tree node for branch hierarchy in sidebar
struct TreeNodeView: View {
    let branch: Branch
    let treeId: String
    @EnvironmentObject var appState: AppState

    private var isSelected: Bool {
        appState.selectedBranchId == branch.id
    }

    var body: some View {
        if branch.children.isEmpty {
            // Leaf node
            branchRow
        } else {
            // Parent node with disclosure
            DisclosureGroup {
                ForEach(branch.children) { child in
                    TreeNodeView(branch: child, treeId: treeId)
                }
            } label: {
                branchRow
            }
        }
    }

    private var branchRow: some View {
        HStack(spacing: 6) {
            branchIcon
                .font(.caption)
                .foregroundStyle(iconColor)

            Text(branch.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            statusIndicator
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectBranch(branch.id, in: treeId)
        }
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
    }

    private var branchIcon: some View {
        Group {
            switch branch.branchType {
            case .conversation:
                Image(systemName: "bubble.left")
            case .implementation:
                Image(systemName: "gearshape")
            case .exploration:
                Image(systemName: "magnifyingglass")
            }
        }
    }

    private var iconColor: Color {
        switch branch.branchType {
        case .conversation: .blue
        case .implementation: .orange
        case .exploration: .purple
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch branch.status {
        case .active:
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        case .archived:
            Image(systemName: "archivebox")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
