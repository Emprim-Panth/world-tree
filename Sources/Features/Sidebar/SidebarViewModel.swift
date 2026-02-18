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
    @Published var trees: [ConversationTree] = []
    @Published var cachedProjects: [CachedProject] = []
    @Published var searchText: String = "" {
        didSet { scheduleContentSearch() }
    }
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

    /// Merged project list: ALL scanned projects (from ProjectCache) + any orphaned tree groups.
    /// Projects with no trees still appear so they're accessible and can have trees created under them.
    var allProjectGroups: [(project: String, trees: [ConversationTree])] {
        // Build a lookup of trees per project name
        let treesByProject = Dictionary(grouping: filteredTrees) {
            let p = $0.project ?? ""
            return p.isEmpty ? "General" : p
        }

        var seen: Set<String> = []
        var result: [(project: String, trees: [ConversationTree])] = []

        // 1. Scanned projects — alphabetical, these are primary
        let filtered = searchText.isEmpty
            ? cachedProjects
            : cachedProjects.filter { $0.name.lowercased().contains(searchText.lowercased()) }
        for p in filtered.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            guard p.name != "General" else { continue }
            seen.insert(p.name)
            result.append((project: p.name, trees: treesByProject[p.name] ?? []))
        }

        // 2. Tree groups whose project name isn't in ProjectCache (e.g. manually entered)
        for group in groupedTrees where group.project != "General" && !seen.contains(group.project) {
            result.append((project: group.project, trees: group.trees))
        }

        // 3. General last
        if let general = treesByProject["General"] {
            result.append((project: "General", trees: general))
        }

        return result
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
                self?.trees = trees
            }
        })
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
