import Foundation
import GRDB

enum SearchScope: String, CaseIterable {
    case trees = "Trees"
    case content = "Content"
}

struct MessageSearchResult: Identifiable {
    let id: String         // message id
    let treeId: String
    let treeName: String
    let branchId: String
    let snippet: String
    let role: MessageRole
}

@MainActor
final class SidebarViewModel: ObservableObject {
    // MARK: - Project ordering

    /// User's preferred project order — persisted across sessions.
    /// Active projects always float above this, but within inactive the user's order wins.
    private(set) var projectOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: "projectOrder") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "projectOrder") }
    }

    /// A project is "active" if it has a tree updated in the last 24 hours.
    /// Active projects always appear at the top of the sidebar.
    private static let activeThreshold: TimeInterval = 86_400 // 24h

    func isActive(_ projectName: String, trees: [ConversationTree]) -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.activeThreshold)
        return trees.contains { $0.updatedAt > cutoff }
    }

    /// Move a project from one position to another in the persistent order.
    /// Only affects the inactive section — active projects are sorted by recency, not manually.
    func moveProject(from source: IndexSet, to destination: Int, in groups: [(project: String, trees: [ConversationTree])]) {
        var order = projectOrder
        // Build the current full order from what's displayed
        let names = groups.map(\.project)
        // Ensure all displayed names are in the order array first
        for name in names where !order.contains(name) {
            order.append(name)
        }
        order.move(fromOffsets: source, toOffset: destination)
        projectOrder = order
        rebuildProjectGroups()
    }

    @Published var trees: [ConversationTree] = [] {
        didSet { rebuildProjectGroups() }
    }
    @Published var cachedProjects: [CachedProject] = [] {
        didSet { rebuildProjectGroups() }
    }
    @Published var searchText: String = "" {
        didSet {
            rebuildProjectGroups()
            scheduleContentSearch()
        }
    }
    /// Pre-computed project groups — recalculated only when trees, projects, or search changes.
    /// Avoids expensive Dictionary rebuilds on every SwiftUI body evaluation.
    @Published private(set) var allProjectGroups: [(project: String, trees: [ConversationTree])] = []
    @Published var searchScope: SearchScope = .trees {
        didSet {
            if searchScope == .content {
                scheduleContentSearch()
            } else {
                contentResults = []
                searchTask?.cancel()
            }
        }
    }
    @Published var contentResults: [MessageSearchResult] = []
    @Published var isSearching: Bool = false
    @Published var isLoading: Bool = false
    @Published var error: String?

    private var observation: AnyDatabaseCancellable?
    private var projectObserver: Any?
    private var searchTask: Task<Void, Never>?
    /// Cached branches per tree ID — survives GRDB observation refreshes.
    private var cachedBranches: [String: [Branch]] = [:]

    var filteredTrees: [ConversationTree] {
        guard !searchText.isEmpty else { return trees }
        let query = searchText.lowercased()
        return trees.filter {
            $0.name.lowercased().contains(query) ||
            ($0.project?.lowercased().contains(query) ?? false)
        }
    }

    private func scheduleContentSearch() {
        guard searchScope == .content else { return }
        searchTask?.cancel()
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            contentResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await runContentSearch(query: query)
        }
    }

    func runContentSearch(query: String) async {
        isSearching = true
        defer { isSearching = false }
        do {
            let messages = try MessageStore.shared.searchMessages(query: query, limit: 40)
            var results: [MessageSearchResult] = []
            for msg in messages {
                guard let branch = try? TreeStore.shared.getBranchBySessionId(msg.sessionId),
                      let tree = trees.first(where: { $0.id == branch.treeId }) else { continue }
                let snippet = msg.content
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let display = snippet.count > 80 ? String(snippet.prefix(77)) + "…" : snippet
                results.append(MessageSearchResult(
                    id: msg.id,
                    treeId: branch.treeId,
                    treeName: tree.name,
                    branchId: branch.id,
                    snippet: display,
                    role: msg.role
                ))
            }
            contentResults = results
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Group trees by project for sidebar sections
    var groupedTrees: [(project: String, trees: [ConversationTree])] {
        let grouped = Dictionary(grouping: filteredTrees) {
            let p = $0.project ?? ""
            return p.isEmpty ? "General" : p
        }
        return grouped.sorted { lhs, rhs in
            // "General" always sorts last
            if lhs.key == "General" { return false }
            if rhs.key == "General" { return true }
            return lhs.key < rhs.key
        }
        .map { (project: $0.key, trees: $0.value) }
    }

    /// Rebuild allProjectGroups from current source data.
    /// Sort order:
    ///   1. Active projects (updated in last 24h) — sorted by most recent activity
    ///   2. Inactive projects — sorted by user's custom order, then alphabetical for new ones
    ///   3. "General" always last
    private func rebuildProjectGroups() {
        let treesByProject = Dictionary(grouping: filteredTrees) {
            let p = $0.project ?? ""
            return p.isEmpty ? "General" : p
        }

        // Collect all known project names (union of ProjectCache + tree groups)
        var allNames: [String] = []
        var seen: Set<String> = []

        let filteredCache = searchText.isEmpty
            ? cachedProjects
            : cachedProjects.filter { $0.name.lowercased().contains(searchText.lowercased()) }
        for p in filteredCache where p.name != "General" {
            if seen.insert(p.name).inserted { allNames.append(p.name) }
        }
        for group in groupedTrees where group.project != "General" && !seen.contains(group.project) {
            seen.insert(group.project)
            allNames.append(group.project)
        }

        // Partition into active vs inactive
        var active: [(name: String, latestActivity: Date)] = []
        var inactive: [String] = []

        for name in allNames {
            let projectTrees = treesByProject[name] ?? []
            if isActive(name, trees: projectTrees) {
                let latest = projectTrees.map(\.updatedAt).max() ?? .distantPast
                active.append((name: name, latestActivity: latest))
            } else {
                inactive.append(name)
            }
        }

        // Active: sort by most recent activity first
        active.sort { $0.latestActivity > $1.latestActivity }

        // Inactive: sort by user's custom order, new projects appended alphabetically
        let order = projectOrder
        inactive.sort { a, b in
            let ai = order.firstIndex(of: a)
            let bi = order.firstIndex(of: b)
            switch (ai, bi) {
            case let (a?, b?): return a < b
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        }

        // Build result
        var result: [(project: String, trees: [ConversationTree])] = []
        for item in active {
            result.append((project: item.name, trees: treesByProject[item.name] ?? []))
        }
        for name in inactive {
            result.append((project: name, trees: treesByProject[name] ?? []))
        }
        if let general = treesByProject["General"] {
            result.append((project: "General", trees: general))
        }

        allProjectGroups = result
    }

    func loadTrees() {
        isLoading = true
        do {
            trees = try TreeStore.shared.listTrees()
            cachedProjects = (try? ProjectCache().getAll()) ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func startObserving() {
        // Watch for ProjectCache updates (filesystem rescan)
        projectObserver = NotificationCenter.default.addObserver(
            forName: .projectCacheUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cachedProjects = (try? ProjectCache().getAll()) ?? []
            }
        }

        guard let dbPool = DatabaseManager.shared.dbPool else { return }

        // GRDB ValueObservation: auto-refreshes when canvas_trees changes
        let observation = ValueObservation.tracking { db -> [ConversationTree] in
            let sql = """
                SELECT t.*,
                    (SELECT COUNT(*) FROM canvas_branches b
                     JOIN messages m ON m.session_id = b.session_id
                     WHERE b.tree_id = t.id) as message_count
                FROM canvas_trees t
                WHERE t.archived = 0
                ORDER BY t.updated_at DESC
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                var tree = ConversationTree(row: row)
                tree.messageCount = row["message_count"] ?? 0
                return tree
            }
        }

        self.observation = observation.start(in: dbPool, onError: { error in
            Task { @MainActor in
                self.error = error.localizedDescription
            }
        }, onChange: { [weak self] trees in
            Task { @MainActor in
                guard let self else { return }
                // Restore previously-loaded branches — the observation query doesn't
                // include branches, so each refresh would wipe them without this.
                var restored = trees
                for i in restored.indices {
                    if let cached = self.cachedBranches[restored[i].id] {
                        restored[i].branches = cached
                    }
                }
                self.trees = restored
            }
        })
    }

    /// Cache loaded branches for a tree so they survive GRDB observation refreshes.
    func cacheBranches(_ branches: [Branch], for treeId: String) {
        cachedBranches[treeId] = branches
        // Immediately update the in-memory tree so the sidebar re-renders
        if let idx = trees.firstIndex(where: { $0.id == treeId }) {
            trees[idx].branches = branches
        }
    }

    func createTree(name: String, project: String? = nil, workingDirectory: String? = nil, template: WorkflowTemplate? = nil) {
        do {
            let tree = try TreeStore.shared.createTree(
                name: name,
                project: project,
                workingDirectory: workingDirectory
            )

            // Auto-create root branch — use template config if provided
            let branchType = template?.branchType ?? .conversation
            let branchTitle = template?.name ?? "Main"
            let contextSnapshot = template?.systemContext

            let branch = try TreeStore.shared.createBranch(
                treeId: tree.id,
                type: branchType,
                title: branchTitle,
                contextSnapshot: contextSnapshot,
                workingDirectory: workingDirectory
            )

            AppState.shared.selectBranch(branch.id, in: tree.id)

            // If template has an initial prompt, send it as the first message
            if let initialPrompt = template?.initialPrompt,
               let sessionId = branch.sessionId {
                _ = try MessageStore.shared.sendMessage(
                    sessionId: sessionId,
                    role: .user,
                    content: initialPrompt
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func archiveTree(_ id: String) {
        do {
            // Load full tree to get branch IDs before archiving, then terminate any live PTYs
            if let tree = try? TreeStore.shared.getTree(id) {
                for branch in tree.branches {
                    BranchTerminalManager.shared.terminate(branchId: branch.id)
                }
            }
            try TreeStore.shared.archiveTree(id)
            if AppState.shared.selectedTreeId == id {
                AppState.shared.selectedTreeId = nil
                AppState.shared.selectedBranchId = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func renameTree(_ id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try TreeStore.shared.renameTree(id, name: trimmed)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func moveTree(_ id: String, toProject: String?) {
        do {
            try TreeStore.shared.moveTree(id, toProject: toProject)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteTree(_ id: String) {
        do {
            // Terminate any live terminal for this tree's branches
            for branch in trees.first(where: { $0.id == id })?.branches ?? [] {
                BranchTerminalManager.shared.terminate(branchId: branch.id)
            }
            try TreeStore.shared.deleteTree(id)
            if AppState.shared.selectedTreeId == id {
                AppState.shared.selectedTreeId = nil
                AppState.shared.selectedBranchId = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Archive all trees in a project group.
    func archiveProject(_ projectName: String) {
        do {
            // Terminate any live terminals in this project's trees
            for tree in trees where (tree.project ?? "General") == projectName {
                if let full = try? TreeStore.shared.getTree(tree.id) {
                    for branch in full.branches {
                        BranchTerminalManager.shared.terminate(branchId: branch.id)
                    }
                }
            }
            try TreeStore.shared.archiveProject(projectName)
            // Clear selection if we archived the selected tree
            if let selId = AppState.shared.selectedTreeId,
               trees.first(where: { $0.id == selId })?.project == projectName {
                AppState.shared.selectedTreeId = nil
                AppState.shared.selectedBranchId = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Delete all trees in a project group (permanent, with cascade).
    func deleteProject(_ projectName: String) {
        do {
            for tree in trees where (tree.project ?? "General") == projectName {
                if let full = try? TreeStore.shared.getTree(tree.id) {
                    for branch in full.branches {
                        BranchTerminalManager.shared.terminate(branchId: branch.id)
                    }
                }
            }
            try TreeStore.shared.deleteProject(projectName)
            if let selId = AppState.shared.selectedTreeId,
               trees.first(where: { $0.id == selId })?.project == projectName {
                AppState.shared.selectedTreeId = nil
                AppState.shared.selectedBranchId = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// All distinct project names currently in use (for "Move to…" submenu)
    var projectNames: [String] {
        let names = trees.compactMap { $0.project }.filter { !$0.isEmpty }
        return Array(Set(names)).sorted()
    }

    // MARK: - Project Path Management

    /// Resolve the filesystem path for a project group.
    /// Prefers ProjectCache (has git/type info); falls back to tree's workingDirectory.
    func resolvedPath(for projectName: String) -> String? {
        if let cached = try? ProjectCache().getByName(projectName) {
            return cached.path
        }
        return groupedTrees
            .first { $0.project == projectName }?
            .trees.first?.workingDirectory
    }

    /// Git info string for a project group (e.g. "main ⚡" or "main").
    func gitInfo(for projectName: String) -> String? {
        guard let cached = try? ProjectCache().getByName(projectName),
              let branch = cached.gitBranch else { return nil }
        return cached.gitDirty ? "\(branch) ⚡" : branch
    }

    /// Project type icon for a project group (SF Symbol name).
    func typeIcon(for projectName: String) -> String {
        guard let cached = try? ProjectCache().getByName(projectName) else {
            return "folder"
        }
        return cached.type.icon
    }

    /// Update the working directory path for all trees in a project group.
    func updateProjectPath(projectName: String, path: String) {
        do {
            try TreeStore.shared.updateWorkingDirectory(forProject: projectName, path: path)
            // Trigger a rescan so git/type info updates
            Task { await ProjectRefreshService.shared.refresh() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
