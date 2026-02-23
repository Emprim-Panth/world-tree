import SwiftUI

struct TreeListView: View {
    @Environment(WorldTreeStore.self) private var store
    @Environment(ConnectionManager.self) private var connectionManager

    var body: some View {
        List(store.trees) { tree in
            Button(action: {
                store.selectTree(tree)
                Task { await connectionManager.send(.listBranches(treeId: tree.id)) }
            }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tree.name)
                        .font(.body)
                    Text("\(tree.messageCount) messages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        }
        .overlay {
            if store.trees.isEmpty {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("No conversation trees found on this server.")
                )
            }
        }
    }
}
