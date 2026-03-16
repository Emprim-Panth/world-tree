import Foundation
import GRDB

enum SearchScope: String, CaseIterable {
    case trees = "Trees"
    case content = "Content"
}

enum SidebarSortOrder: String, CaseIterable {
    case recentDesc = "recentDesc"
    case recentAsc  = "recentAsc"
    case alphaAsc   = "alphaAsc"
    case alphaDesc  = "alphaDesc"

    var label: String {
        switch self {
        case .recentDesc: return "Newest First"
        case .recentAsc:  return "Oldest First"
        case .alphaAsc:   return "A → Z"
        case .alphaDesc:  return "Z → A"
        }
    }
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

    nonisolated static func visibleSidebarTrees(from trees: [ConversationTree]) -> [ConversationTree] {
        trees.filter { !$0.isTelegramBridge }
    }

    /// User's preferred project order — persisted across sessions.
    /// Active projects always float above this, but within inactive the user's order wins.
    private(set) var projectOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: AppConstants.projectOrderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: AppConstants.projectOrderKey) }
    }

    /// A project is "active" if it has a tree updated in the last 24 hours.
    /// Active projects always appear at the top of the sidebar.
    private static let activeThreshold: TimeInterval = 86_400 // 24h

    func isActive(_ projectName: String, trees: [ConversationTree]) -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.activeThreshold)
        return Self.projectActivity(
            for: projectName,
            trees: trees,
            cachedProject: cachedProject(named: projectName)
        ) > cutoff
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

    @Published var sortOrder: SidebarSortOrder = {
        guard let raw = UserDefaults.standard.string(forKey: AppConstants.sidebarSortOrderKey),
              let order = SidebarSortOrder(rawValue: raw) else { return .recentDesc }
        return order
    }() {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: AppConstants.sidebarSortOrderKey)
            rebuildProjectGroups()
        }
    }

    @Published var trees: [ConversationTree] = []
    @Published var cachedProjects: [CachedProject] = []
    @Published var searchText: String = "" {
        didSet {
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self?.rebuildProjectGroups()
                self?.scheduleContentSearch()
            }
        }
    }
    /// Pre-computed project groups — recalculated only when trees, projects, or search changes.
    /// Avoids expensive Dictionary rebuilds on every SwiftUI body evaluation.
    @Published private(set) var allProjectGroups: [(project: String, trees: [ConversationTree])] = []
    @Published private(set) var recentProjectGroups: [(project: String, trees: [ConversationTree])] = []
    /// Projects from ProjectCache that have no chats — shown collapsed at the bottom of the sidebar.
    @Published private(set) var dormantProjectGroups: [(project: String, trees: [ConversationTree])] = []
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
    private var searchDebounceTask: Task<Void, Never>?
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
            let sessionIds = messages.map(\.sessionId)
            let branchesBySession = (try? TreeStore.shared.getBranchesBySessionIds(sessionIds)) ?? [:]
            var results: [MessageSearchResult] = []
            for msg in messages {
                guard let branch = branchesBySession[msg.sessionId],
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

    /// Rebuild allProjectGroups from current source data.
    /// Sort order: most recently active project first, "General" always last.
    /// The latest tree.updatedAt across all trees in a project determines its rank.
    private func rebuildProjectGroups() {
        let visibleTrees = Self.visibleSidebarTrees(from: filteredTrees)
        var treesByProject: [String: [ConversationTree]] = [:]
        for tree in visibleTrees {
            let rawProject = tree.project ?? ""
            let projectName = rawProject.isEmpty ? AppConstants.defaultProjectName : rawProject
            treesByProject[projectName, default: []].append(tree)
        }

        // Collect all known project names (union of ProjectCache + tree groups)
        // Projects with chats (trees) always appear in the main list.
        // Projects from ProjectCache with NO chats are shown in a collapsed "dormant" section.
        var chatNames: [String] = []     // has at least one tree
        var dormantNames: [String] = []  // only in ProjectCache, no trees
        var seenLowercased: Set<String> = []

        let filteredCache = searchText.isEmpty
            ? cachedProjects
            : cachedProjects.filter { $0.name.lowercased().contains(searchText.lowercased()) }

        // First pass: names that appear in treesByProject (have chats)
        for project in treesByProject.keys where project != AppConstants.defaultProjectName {
            let key = project.lowercased()
            if seenLowercased.insert(key).inserted { chatNames.append(project) }
        }
        // Second pass: cached projects that have no trees → dormant
        for p in filteredCache where p.name != AppConstants.defaultProjectName {
            let key = p.name.lowercased()
            if seenLowercased.insert(key).inserted { dormantNames.append(p.name) }
        }

        let allNames = chatNames

        var cachedProjectsByName: [String: CachedProject] = [:]
        for project in cachedProjects {
            let key = project.name.lowercased()
            let existing = cachedProjectsByName[key]
            if let existing {
                cachedProjectsByName[key] = existing.lastModified >= project.lastModified ? existing : project
            } else {
                cachedProjectsByName[key] = project
            }
        }
        func cachedProject(for projectName: String) -> CachedProject? {
            cachedProjectsByName[projectName.lowercased()]
        }

        let cutoff = Date().addingTimeInterval(-Self.activeThreshold)
        let activeNames = allNames.filter {
            Self.projectActivity(
                for: $0,
                trees: treesByProject[$0] ?? [],
                cachedProject: cachedProject(for: $0)
            ) > cutoff
        }
            .sorted {
                Self.projectActivity(
                    for: $0,
                    trees: treesByProject[$0] ?? [],
                    cachedProject: cachedProject(for: $0)
                ) > Self.projectActivity(
                    for: $1,
                    trees: treesByProject[$1] ?? [],
                    cachedProject: cachedProject(for: $1)
                )
            }
        let activeSet = Set(activeNames)
        let inactiveNames = allNames.filter { !activeSet.contains($0) }

        let sorted = Self.sortProjectNames(
            inactiveNames,
            sortOrder: sortOrder,
            manualOrder: projectOrder
        ) { projectName in
            Self.projectActivity(
                for: projectName,
                trees: treesByProject[projectName] ?? [],
                cachedProject: cachedProject(for: projectName)
            )
        }

        var result: [(project: String, trees: [ConversationTree])] = (activeNames + sorted).map {
            (project: $0, trees: sortTrees(treesByProject[$0] ?? []))
        }
        if let general = treesByProject[AppConstants.defaultProjectName] {
            result.append((project: AppConstants.defaultProjectName, trees: sortTrees(general)))
        }

        // Build dormant list — chat-less projects, sorted alphabetically, hidden by default
        dormantProjectGroups = dormantNames
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { (project: $0, trees: []) }

        allProjectGroups = result
        // Recents: walk `visibleTrees` in DB-sort order (already COALESCE(last_message_at, updated_at) DESC)
        // and take the first 4 unique non-General project names.
        // This sidesteps any in-memory nil-date edge cases — the DB ordering is authoritative.
        var recentSeen: [String] = []
        var recentSeenSet: Set<String> = []
        for tree in visibleTrees {
            let proj = tree.project.flatMap { $0.isEmpty ? nil : $0 } ?? AppConstants.defaultProjectName
            guard proj != AppConstants.defaultProjectName else { continue }
            if recentSeenSet.insert(proj).inserted {
                recentSeen.append(proj)
                if recentSeen.count == 4 { break }
            }
        }
        recentProjectGroups = recentSeen.map { proj in
            (project: proj, trees: sortTrees(treesByProject[proj] ?? []))
        }
    }

    /// Sort an array of trees according to the current sortOrder.
    private func sortTrees(_ trees: [ConversationTree]) -> [ConversationTree] {
        trees.sorted { a, b in
            switch sortOrder {
            case .recentDesc:
                return (a.lastMessageAt ?? a.updatedAt) > (b.lastMessageAt ?? b.updatedAt)
            case .recentAsc:
                return (a.lastMessageAt ?? a.updatedAt) < (b.lastMessageAt ?? b.updatedAt)
            case .alphaAsc:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .alphaDesc:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedDescending
            }
        }
    }

    nonisolated static func projectActivity(
        for projectName: String,
        trees: [ConversationTree],
        cachedProject: CachedProject?
    ) -> Date {
        // Chat activity always wins. File mtime is only a fallback when there are no chats.
        if let treeActivity = trees.compactMap({ $0.lastMessageAt ?? $0.updatedAt }).max() {
            return treeActivity
        }
        return cachedProject?.lastModified ?? .distantPast
    }

    nonisolated static func sortProjectNames(
        _ names: [String],
        sortOrder: SidebarSortOrder,
        manualOrder: [String],
        activity: (String) -> Date
    ) -> [String] {
        names.sorted { a, b in
            switch sortOrder {
            case .recentDesc, .recentAsc:
                let aDate = activity(a)
                let bDate = activity(b)
                if aDate != bDate {
                    return sortOrder == .recentDesc ? aDate > bDate : aDate < bDate
                }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            case .alphaAsc, .alphaDesc:
                let aManual = manualOrder.firstIndex(of: a)
                let bManual = manualOrder.firstIndex(of: b)
                switch (aManual, bManual) {
                case let (lhs?, rhs?):
                    if lhs != rhs { return lhs < rhs }
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    break
                }

                if sortOrder == .alphaAsc {
                    return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
                }
                return a.localizedCaseInsensitiveCompare(b) == .orderedDescending
            }
        }
    }

    func latestActivity(for projectName: String, trees: [ConversationTree]? = nil) -> Date? {
        let sourceTrees = trees ?? allProjectGroups.first(where: { $0.project == projectName })?.trees ?? []
        let activity = Self.projectActivity(
            for: projectName,
            trees: sourceTrees,
            cachedProject: cachedProject(named: projectName)
        )
        return activity == .distantPast ? nil : activity
    }

    func latestActivityLabel(for projectName: String, trees: [ConversationTree]? = nil) -> String? {
        guard let activity = latestActivity(for: projectName, trees: trees) else { return nil }
        return RelativeDateTimeFormatter().localizedString(for: activity, relativeTo: Date())
    }

    deinit {
        searchTask?.cancel()
        searchDebounceTask?.cancel()
        if let observer = projectObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func loadTrees() {
        isLoading = true
        do {
            trees = try TreeStore.shared.getTrees()
            cachedProjects = (try? ProjectCache().getAll()) ?? []
            rebuildProjectGroups()
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
                self?.rebuildProjectGroups()
            }
        }

        guard let dbPool = DatabaseManager.shared.dbPool else { return }

        // GRDB ValueObservation: auto-refreshes when canvas_trees changes.
        // trackingConstantRegion: only observes canvas_trees — no join on messages.
        // Denormalized columns (message_count, last_message_at, last_assistant_snippet)
        // are kept in sync by SQLite triggers (v17 migration), so the observation
        // only fires when canvas_trees rows actually change, NOT on every message insert.
        let observation = ValueObservation.trackingConstantRegion { db -> [ConversationTree] in
            let sql = """
                SELECT t.*
                FROM canvas_trees t
                WHERE t.archived = 0
                ORDER BY COALESCE(t.last_message_at, t.updated_at) DESC
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                var tree = ConversationTree(row: row)
                tree.messageCount = row["message_count"] ?? 0
                return tree
            }
        }

        self.observation = observation.start(
            in: dbPool,
            scheduling: .async(onQueue: .main),
            onError: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.error = error.localizedDescription
                }
            }, onChange: { [weak self] trees in
                Task { @MainActor in
                    guard let self else { return }
                    // Batch-fetch all branches in one query instead of per-tree lookups
                    let treeIds = trees.map(\.id)
                    let allBranches = (try? TreeStore.shared.getBranchesByTreeIds(treeIds)) ?? [:]

                    var restored = trees
                    for i in restored.indices {
                        restored[i].branches = allBranches[restored[i].id]
                            ?? self.cachedBranches[restored[i].id]
                            ?? []
                    }
                    // Update cache with freshly fetched branches
                    for (treeId, branches) in allBranches {
                        self.cachedBranches[treeId] = branches
                    }
                    self.trees = restored
                    self.rebuildProjectGroups()
                }
            }
        )
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
                model: template?.suggestedModel,
                contextSnapshot: contextSnapshot,
                workingDirectory: workingDirectory
            )

            AppState.shared.selectBranch(branch.id, in: tree.id)

            // If template has an initial prompt, queue it for auto-send via the provider pipeline.
            // DocumentEditorView.onAppear checks this key and submits through viewModel.submitInput().
            if let initialPrompt = template?.initialPrompt,
               let sessionId = branch.sessionId {
                UserDefaults.standard.set(initialPrompt, forKey: "pending_synthesis_\(sessionId)")
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
            for tree in trees where (tree.project ?? AppConstants.defaultProjectName) == projectName {
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
            for tree in trees where (tree.project ?? AppConstants.defaultProjectName) == projectName {
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
        return allProjectGroups
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

    private func cachedProject(named projectName: String) -> CachedProject? {
        cachedProjects.first { $0.name.caseInsensitiveCompare(projectName) == .orderedSame }
    }
}
