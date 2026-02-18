import Foundation
import GRDB

/// CRUD operations for conversation trees and branches.
/// Reads/writes canvas_* tables and creates sessions in the existing sessions table.
@MainActor
final class TreeStore {
    static let shared = TreeStore()

    private var db: DatabaseManager { .shared }

    private init() {}

    // MARK: - Trees

    func createTree(
        name: String,
        project: String? = nil,
        workingDirectory: String? = nil
    ) throws -> ConversationTree {
        let tree = ConversationTree(
            id: UUID().uuidString,
            name: name,
            project: project,
            workingDirectory: workingDirectory,
            createdAt: Date(),
            updatedAt: Date(),
            archived: false
        )
        try db.write { db in
            try tree.insert(db)
        }
        return tree
    }

    func listTrees(includeArchived: Bool = false) throws -> [ConversationTree] {
        try db.read { db in
            var sql = """
                SELECT t.*,
                    (SELECT COUNT(*) FROM canvas_branches b
                     JOIN sessions s ON b.session_id = s.id
                     JOIN messages m ON m.session_id = s.id
                     WHERE b.tree_id = t.id) as message_count,
                    (SELECT COUNT(*) FROM canvas_branches b
                     WHERE b.tree_id = t.id AND b.status = 'active') as branch_count,
                    (SELECT m.content FROM messages m
                     JOIN canvas_branches b ON m.session_id = b.session_id
                     WHERE b.tree_id = t.id AND m.role = 'assistant'
                     ORDER BY m.timestamp DESC LIMIT 1) as last_message_snippet
                FROM canvas_trees t
                """
            if !includeArchived {
                sql += " WHERE t.archived = 0"
            }
            sql += " ORDER BY t.updated_at DESC"

            return try Row.fetchAll(db, sql: sql).map { row in
                var tree = ConversationTree(row: row)
                tree.messageCount = row["message_count"] ?? 0
                tree.branchCount = row["branch_count"] ?? 0
                tree.lastMessageSnippet = row["last_message_snippet"]
                return tree
            }
        }
    }

    func getTree(_ id: String) throws -> ConversationTree? {
        try db.read { db in
            guard var tree = try ConversationTree.fetchOne(db, key: id) else {
                return nil
            }

            let branches = try Branch.filter(Column("tree_id") == id)
                .order(Column("created_at"))
                .fetchAll(db)

            tree.branches = Self.buildBranchTree(from: branches)
            return tree
        }
    }

    func updateTreeTimestamp(_ id: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE canvas_trees SET updated_at = datetime('now') WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func archiveTree(_ id: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE canvas_trees SET archived = 1, updated_at = datetime('now') WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func renameTree(_ id: String, name: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE canvas_trees SET name = ?, updated_at = datetime('now') WHERE id = ?",
                arguments: [name, id]
            )
        }
    }

    func moveTree(_ id: String, toProject: String?) throws {
        try db.write { db in
            if let project = toProject, !project.isEmpty {
                try db.execute(
                    sql: "UPDATE canvas_trees SET project = ?, updated_at = datetime('now') WHERE id = ?",
                    arguments: [project, id]
                )
            } else {
                try db.execute(
                    sql: "UPDATE canvas_trees SET project = NULL, updated_at = datetime('now') WHERE id = ?",
                    arguments: [id]
                )
            }
        }
    }

    /// Update the working directory for all trees in a given project group.
    /// Used when the user edits a project's path inline in the sidebar.
    func updateWorkingDirectory(forProject project: String, path: String) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE canvas_trees
                    SET working_directory = ?, updated_at = datetime('now')
                    WHERE project = ?
                    """,
                arguments: [path, project]
            )
        }
    }

    // MARK: - Project-Level Operations

    /// Archive all trees in a project group — removes them from the active sidebar.
    func archiveProject(_ projectName: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE canvas_trees SET archived = 1, updated_at = datetime('now') WHERE project = ?",
                arguments: [projectName]
            )
        }
    }

    /// Delete all trees in a project group (full cascade: messages → sessions → branches → trees).
    func deleteProject(_ projectName: String) throws {
        let treeIds: [String] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id FROM canvas_trees WHERE project = ?", arguments: [projectName])
            return rows.map { $0["id"] }
        }
        for id in treeIds {
            try deleteTree(id)
        }
    }

    func deleteTree(_ id: String) throws {
        try db.write { db in
            // Delete messages for all branches in this tree
            try db.execute(
                sql: """
                    DELETE FROM messages WHERE session_id IN (
                        SELECT session_id FROM canvas_branches WHERE tree_id = ?
                    )
                    """,
                arguments: [id]
            )
            // Delete sessions for all branches
            try db.execute(
                sql: """
                    DELETE FROM sessions WHERE id IN (
                        SELECT session_id FROM canvas_branches WHERE tree_id = ?
                    )
                    """,
                arguments: [id]
            )
            // Delete branches
            try db.execute(
                sql: "DELETE FROM canvas_branches WHERE tree_id = ?",
                arguments: [id]
            )
            // Delete tree
            try db.execute(
                sql: "DELETE FROM canvas_trees WHERE id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - Branches

    /// Creates a new branch with an associated session.
    /// The session is created in the existing `sessions` table so hooks remain compatible.
    func createBranch(
        treeId: String,
        parentBranch: String? = nil,
        forkFromMessage: String? = nil,
        type: BranchType = .conversation,
        title: String? = nil,
        model: String? = nil,
        contextSnapshot: String? = nil,
        workingDirectory: String? = nil
    ) throws -> Branch {
        try db.write { db in
            // Create a session in the existing sessions table (cortana-core compatible)
            let sessionId = UUID().uuidString
            let cwd = workingDirectory ?? "~/Development"
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, terminal_id, working_directory, description, started_at)
                    VALUES (?, ?, ?, ?, datetime('now'))
                    """,
                arguments: [sessionId, "canvas", cwd, title ?? "Canvas branch"]
            )

            // Create the branch overlay
            let branch = Branch(
                id: UUID().uuidString,
                treeId: treeId,
                sessionId: sessionId,
                parentBranchId: parentBranch,
                forkFromMessageId: forkFromMessage,
                branchType: type,
                title: title,
                status: .active,
                model: model,
                contextSnapshot: contextSnapshot,
                collapsed: false,
                createdAt: Date(),
                updatedAt: Date()
            )
            try branch.insert(db)

            // If context snapshot provided, inject as system message
            if let context = contextSnapshot, !context.isEmpty {
                try db.execute(
                    sql: """
                        INSERT INTO messages (session_id, role, content, timestamp)
                        VALUES (?, 'system', ?, datetime('now'))
                        """,
                    arguments: [sessionId, context]
                )
            }

            return branch
        }
    }

    func updateBranch(
        _ id: String,
        status: BranchStatus? = nil,
        summary: String? = nil,
        title: String? = nil,
        daemonTaskId: String? = nil,
        collapsed: Bool? = nil
    ) throws {
        try db.write { db in
            var setClauses: [String] = []
            var args: [DatabaseValueConvertible?] = []

            if let status {
                setClauses.append("status = ?")
                args.append(status.rawValue)
            }
            if let summary {
                setClauses.append("summary = ?")
                args.append(summary)
            }
            if let title {
                setClauses.append("title = ?")
                args.append(title)
            }
            if let daemonTaskId {
                setClauses.append("daemon_task_id = ?")
                args.append(daemonTaskId)
            }
            if let collapsed {
                setClauses.append("collapsed = ?")
                args.append(collapsed ? 1 : 0)
            }

            guard !setClauses.isEmpty else { return }
            setClauses.append("updated_at = datetime('now')")
            args.append(id)

            let sql = "UPDATE canvas_branches SET \(setClauses.joined(separator: ", ")) WHERE id = ?"
            try db.execute(sql: sql, arguments: StatementArguments(args))
        }
    }

    func getBranch(_ id: String) throws -> Branch? {
        try db.read { db in
            try Branch.fetchOne(db, key: id)
        }
    }

    /// Returns branches that fork from a specific message
    func branchesFromMessage(_ messageId: Int) throws -> [Branch] {
        try db.read { db in
            try Branch.filter(Column("fork_from_message_id") == messageId).fetchAll(db)
        }
    }

    /// Find the branch whose associated session_id matches the given ID.
    /// Used by CanvasServer to resume a conversation from an external client.
    func getBranchBySessionId(_ sessionId: String) throws -> Branch? {
        try db.read { db in
            try Branch.filter(Column("session_id") == sessionId).fetchOne(db)
        }
    }

    // MARK: - Branch Navigation

    /// Returns the path from the root branch to the given branch (inclusive).
    /// Uses a recursive CTE instead of loading every branch in the tree.
    func branchPath(to branchId: String) throws -> [Branch] {
        try db.read { db in
            let sql = """
                WITH RECURSIVE ancestors(id) AS (
                    SELECT id FROM canvas_branches WHERE id = ?
                    UNION ALL
                    SELECT cb.parent_branch_id FROM canvas_branches cb
                    JOIN ancestors a ON cb.id = a.id
                    WHERE cb.parent_branch_id IS NOT NULL
                )
                SELECT cb.* FROM canvas_branches cb
                JOIN ancestors a ON cb.id = a.id
                ORDER BY cb.created_at ASC
                """
            return try Branch.fetchAll(db, sql: sql, arguments: [branchId])
        }
    }

    /// Returns sibling branches (same parent) excluding the given branch.
    func getSiblings(of branchId: String) throws -> [Branch] {
        try db.read { db in
            guard let branch = try Branch.fetchOne(db, key: branchId) else { return [] }

            if let parentId = branch.parentBranchId {
                return try Branch
                    .filter(Column("parent_branch_id") == parentId && Column("id") != branchId)
                    .order(Column("created_at"))
                    .fetchAll(db)
            } else {
                // Root branches — siblings are other root branches in same tree
                return try Branch
                    .filter(Column("tree_id") == branch.treeId
                            && Column("parent_branch_id") == nil
                            && Column("id") != branchId)
                    .order(Column("created_at"))
                    .fetchAll(db)
            }
        }
    }

    // MARK: - Tree Building

    /// Builds a tree hierarchy from a flat list of branches
    static func buildBranchTree(from branches: [Branch]) -> [Branch] {
        var lookup: [String: Branch] = [:]
        for branch in branches {
            lookup[branch.id] = branch
        }

        // Attach children to parents.
        // Branch is a value type — must copy, mutate, then reassign back into the dictionary.
        for branch in branches {
            if let parentId = branch.parentBranchId, var parent = lookup[parentId] {
                parent.children.append(branch)
                lookup[parentId] = parent
            }
        }

        // Return root branches (no parent)
        return branches
            .filter { $0.parentBranchId == nil }
            .map { lookup[$0.id]! }
    }
}
