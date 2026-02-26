import SwiftUI

struct TreeListView: View {
    @Environment(WorldTreeStore.self) private var store

    /// Trees grouped by project, sorted by most-recent update within each group.
    private var treesByProject: [(project: String, trees: [TreeSummary])] {
        var groups: [String: [TreeSummary]] = [:]
        for tree in store.trees {
            let key = tree.project ?? "General"
            groups[key, default: []].append(tree)
        }
        return groups
            .map { (project: $0.key, trees: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { a, b in
                let aDate = a.trees.first?.updatedAt ?? ""
                let bDate = b.trees.first?.updatedAt ?? ""
                return aDate > bDate
            }
    }

    var body: some View {
        List {
            ForEach(treesByProject, id: \.project) { group in
                Section(group.project) {
                    ForEach(group.trees) { tree in
                        TreeRow(tree: tree)
                    }
                }
            }
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

// MARK: - Tree Row

private struct TreeRow: View {
    @Environment(WorldTreeStore.self) private var store
    let tree: TreeSummary

    var body: some View {
        Button(action: {
            store.selectTree(tree)
            store.pendingAutoSelectBranch = true
            // listBranches is sent by ConversationView.onChange(of: currentTree?.id)
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
