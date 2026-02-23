import SwiftUI

struct TreeListView: View {
    @Environment(WorldTreeStore.self) private var store
    @Environment(ConnectionManager.self) private var connectionManager

    private var sortedTrees: [TreeSummary] {
        store.trees.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        List(sortedTrees) { tree in
            Button(action: {
                store.selectTree(tree)
                store.pendingAutoSelectBranch = true
                Task { await connectionManager.send(.listBranches(treeId: tree.id)) }
            }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tree.name)
                        .font(.body)
                    HStack(spacing: 6) {
                        Text(relativeTime(from: tree.updatedAt))
                        Text("·")
                        Text("\(tree.messageCount) messages")
                    }
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

    private func relativeTime(from isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: isoString)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: isoString)
        }
        guard let date else { return "" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .short
        return rel.localizedString(for: date, relativeTo: Date())
    }
}
