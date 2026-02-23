import SwiftUI

/// iPad center column: branch list for the selected tree.
struct BranchContentView: View {
    @Environment(WorldTreeStore.self) private var store
    @Environment(ConnectionManager.self) private var connectionManager

    @Binding var showNewBranchSheet: Bool

    /// String selection binding — List requires Hashable, String qualifies.
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { store.currentBranch?.id },
            set: { newId in
                guard let id = newId,
                      let branch = store.branches.first(where: { $0.id == id }),
                      let tree = store.currentTree else { return }
                store.selectBranch(branch)
                Task {
                    await connectionManager.send(.subscribe(treeId: tree.id, branchId: branch.id))
                    await connectionManager.send(.loadHistory(branchId: branch.id))
                }
            }
        )
    }

    var body: some View {
        Group {
            if store.currentTree == nil {
                // No tree selected
                ContentUnavailableView(
                    "Select a Tree",
                    systemImage: "leaf",
                    description: Text("Choose a conversation tree from the sidebar.")
                )
            } else if store.branches.isEmpty {
                // Loading skeleton
                List {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonBranchRow()
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            } else {
                branchList
            }
        }
        .navigationTitle(store.currentTree?.name ?? "Branches")
        .toolbar {
            if store.currentTree != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewBranchSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    private var branchList: some View {
        List(store.branches, id: \.id, selection: selectionBinding) { branch in
            BranchContentRow(branch: branch, isSelected: store.currentBranch?.id == branch.id)
                .tag(branch.id)
                .listRowBackground(
                    store.currentBranch?.id == branch.id
                        ? DesignTokens.Color.brandGold.opacity(0.12)
                        : Color.clear
                )
        }
        .listStyle(.plain)
    }
}

// MARK: - Branch Row

private struct BranchContentRow: View {
    let branch: BranchSummary
    let isSelected: Bool

    private var leafIcon: String {
        branch.branchType == "main" ? "leaf.fill" : "leaf"
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: leafIcon)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? DesignTokens.Color.brandGold : DesignTokens.Color.brandAsh)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(branch.displayName)
                    .font(DesignTokens.Typography.branchName)
                    .foregroundStyle(DesignTokens.Color.brandParchment)
                    .lineLimit(1)

                statusBadge
            }

            Spacer()
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch branch.status {
        case "active":
            Text(branch.status.capitalized)
                .font(DesignTokens.Typography.statusBadge)
                .foregroundStyle(DesignTokens.Color.brandGold)
                .padding(.horizontal, DesignTokens.Spacing.xs)
                .padding(.vertical, DesignTokens.Spacing.xxs)
                .background(DesignTokens.Color.brandGold.opacity(0.15), in: Capsule())
        case "archived":
            Text(branch.status.capitalized)
                .font(DesignTokens.Typography.statusBadge)
                .foregroundStyle(Color.gray)
                .padding(.horizontal, DesignTokens.Spacing.xs)
                .padding(.vertical, DesignTokens.Spacing.xxs)
                .background(Color.gray.opacity(0.12), in: Capsule())
        default: // idle
            Text(branch.status.capitalized)
                .font(DesignTokens.Typography.statusBadge)
                .foregroundStyle(DesignTokens.Color.brandAsh)
        }
    }
}
