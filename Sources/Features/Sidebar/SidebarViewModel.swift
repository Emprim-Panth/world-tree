import Foundation
import GRDB

@MainActor
final class SidebarViewModel: ObservableObject {
    @Published var trees: [ConversationTree] = []
    @Published var searchText: String = ""
    @Published var isLoading: Bool = false
    @Published var error: String?

    private var observation: AnyDatabaseCancellable?

    var filteredTrees: [ConversationTree] {
        guard !searchText.isEmpty else { return trees }
        let query = searchText.lowercased()
        return trees.filter {
            $0.name.lowercased().contains(query) ||
            ($0.project?.lowercased().contains(query) ?? false)
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

    func loadTrees() {
        isLoading = true
        do {
            trees = try TreeStore.shared.listTrees()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func startObserving() {
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

    /// All distinct project names currently in use (for "Move to…" submenu)
    var projectNames: [String] {
        let names = trees.compactMap { $0.project }.filter { !$0.isEmpty }
        return Array(Set(names)).sorted()
    }
}
