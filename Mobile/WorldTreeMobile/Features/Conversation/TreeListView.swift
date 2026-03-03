import SwiftUI

struct TreeListView: View {
    @Environment(WorldTreeStore.self) private var store
    @Environment(ConnectionManager.self) private var connectionManager

    @State private var searchText = ""
    @State private var treeToRename: TreeSummary?
    @State private var treeToDelete: TreeSummary?
    @State private var renameText = ""

    /// Trees grouped by project, filtered by search, sorted by most-recent update.
    private var filteredTreesByProject: [(project: String, trees: [TreeSummary])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var groups: [String: [TreeSummary]] = [:]
        for tree in store.trees {
            guard query.isEmpty
                    || tree.name.lowercased().contains(query)
                    || (tree.project ?? "").lowercased().contains(query)
            else { continue }
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
            ForEach(filteredTreesByProject, id: \.project) { group in
                Section(group.project) {
                    ForEach(group.trees) { tree in
                        TreeRow(
                            tree: tree,
                            onRename: {
                                treeToRename = tree
                                renameText = tree.name
                            },
                            onDelete: { treeToDelete = tree }
                        )
                    }
                }
            }
        }
        .refreshable {
            await connectionManager.send(.listTrees())
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search conversations"
        )
        .overlay {
            if store.trees.isEmpty {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("No conversation trees found on this server.")
                )
            } else if !searchText.isEmpty && filteredTreesByProject.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        // Rename alert
        .alert("Rename Conversation", isPresented: Binding(
            get: { treeToRename != nil },
            set: { if !$0 { treeToRename = nil } }
        )) {
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
            Button("Rename") {
                if let tree = treeToRename {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task { await connectionManager.send(.renameTree(treeId: tree.id, name: name)) }
                }
                treeToRename = nil
            }
            Button("Cancel", role: .cancel) { treeToRename = nil }
        }
        // Delete confirmation
        .alert("Delete Conversation", isPresented: Binding(
            get: { treeToDelete != nil },
            set: { if !$0 { treeToDelete = nil } }
        ), presenting: treeToDelete) { tree in
            Button("Delete", role: .destructive) {
                Task { await connectionManager.send(.deleteTree(treeId: tree.id)) }
                if store.currentTree?.id == tree.id { store.clearTree() }
                treeToDelete = nil
            }
            Button("Cancel", role: .cancel) { treeToDelete = nil }
        } message: { tree in
            Text("\"\(tree.name)\" and all its branches will be permanently deleted.")
        }
    }
}

// MARK: - Tree Row

private struct TreeRow: View {
    @Environment(WorldTreeStore.self) private var store
    let tree: TreeSummary
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: {
            store.selectTree(tree)
            store.pendingAutoSelectBranch = true
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
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
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
