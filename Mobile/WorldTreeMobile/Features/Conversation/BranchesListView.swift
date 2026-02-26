import SwiftUI

struct BranchesListView: View {
    @Environment(WorldTreeStore.self) private var store
    @Environment(ConnectionManager.self) private var connectionManager

    var body: some View {
        List(store.branches as [BranchSummary]) { (branch: BranchSummary) in
            Button(action: {
                store.selectBranch(branch)
                guard let tree = store.currentTree else { return }
                Task {
                    await connectionManager.send(.subscribe(treeId: tree.id, branchId: branch.id))
                    await connectionManager.send(.loadHistory(branchId: branch.id))
                }
            }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(branch.displayName)
                        .font(.body)
                    HStack(spacing: 8) {
                        Text(branch.status.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if branch.branchType != "main" {
                            Text(branch.branchType)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .overlay {
            if store.isLoadingBranches {
                ProgressView()
                    .progressViewStyle(.circular)
            } else if store.branches.isEmpty {
                ContentUnavailableView(
                    "No Branches",
                    systemImage: "arrow.triangle.branch",
                    description: Text("This conversation has no branches yet.")
                )
            }
        }
    }
}
