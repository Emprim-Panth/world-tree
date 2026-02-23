import SwiftUI

/// iPad sidebar: list of conversation trees with search and create.
struct TreeSidebarView: View {
    @Environment(WorldTreeStore.self) private var store
    @Environment(ConnectionManager.self) private var connectionManager

    @State private var searchText = ""
    @Binding var showNewTreeSheet: Bool

    private var filteredTrees: [TreeSummary] {
        guard !searchText.isEmpty else { return store.trees }
        return store.trees.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// String selection binding — List requires Hashable, String qualifies.
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { store.currentTree?.id },
            set: { newId in
                guard let id = newId,
                      let tree = store.trees.first(where: { $0.id == id }) else { return }
                store.selectTree(tree)
                Task { await connectionManager.send(.listBranches(treeId: tree.id)) }
                store.currentBranch = nil
            }
        )
    }

    var body: some View {
        List(filteredTrees, id: \.id, selection: selectionBinding) { tree in
            TreeSidebarRow(tree: tree, isSelected: store.currentTree?.id == tree.id)
                .tag(tree.id)
                .listRowBackground(
                    store.currentTree?.id == tree.id
                        ? DesignTokens.Color.brandGold.opacity(0.15)
                        : Color.clear
                )
        }
        .listStyle(.sidebar)
        .overlay {
            if store.trees.isEmpty {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Tap + to create your first tree.")
                )
            } else if filteredTrees.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: "Search trees")
        .navigationTitle("Trees")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewTreeSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

// MARK: - Tree Row

private struct TreeSidebarRow: View {
    let tree: TreeSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Circle()
                .fill(isSelected ? DesignTokens.Color.brandGold : DesignTokens.Color.brandAsh)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(tree.name)
                    .font(DesignTokens.Typography.treeName)
                    .foregroundStyle(DesignTokens.Color.brandParchment)
                    .lineLimit(1)

                Text("\(tree.messageCount) messages")
                    .font(DesignTokens.Typography.metaLabel)
                    .foregroundStyle(DesignTokens.Color.brandAsh)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}
