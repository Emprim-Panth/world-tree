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
                     WHERE b.tree_id = t.id) as message_count
                FROM canvas_trees t
                """
            if !includeArchived {
                sql += " WHERE t.archived = 0"
            }
            sql += " ORDER BY t.updated_at DESC"

            return try Row.fetchAll(db, sql: sql).map { row in
                var tree = ConversationTree(row: row)
                tree.messageCount = row["message_count"] ?? 0
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

    // MARK: - Branches

    /// Creates a new branch with an associated session.
    /// The session is created in the existing `sessions` table so hooks remain compatible.
    func createBranch(
        treeId: String,
        parentBranch: String? = nil,
        forkFromMessage: Int? = nil,
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
            if let status {
                try db.execute(sql: "UPDATE canvas_branches SET status = ?, updated_at = datetime('now') WHERE id = ?", arguments: [status.rawValue, id])
            }
            if let summary {
                try db.execute(sql: "UPDATE canvas_branches SET summary = ?, updated_at = datetime('now') WHERE id = ?", arguments: [summary, id])
            }
            if let title {
                try db.execute(sql: "UPDATE canvas_branches SET title = ?, updated_at = datetime('now') WHERE id = ?", arguments: [title, id])
            }
            if let daemonTaskId {
                try db.execute(sql: "UPDATE canvas_branches SET daemon_task_id = ?, updated_at = datetime('now') WHERE id = ?", arguments: [daemonTaskId, id])
            }
            if let collapsed {
                try db.execute(sql: "UPDATE canvas_branches SET collapsed = ?, updated_at = datetime('now') WHERE id = ?", arguments: [collapsed ? 1 : 0, id])
            }
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

    // MARK: - Tree Building

    /// Builds a tree hierarchy from a flat list of branches
    static func buildBranchTree(from branches: [Branch]) -> [Branch] {
        var lookup: [String: Branch] = [:]
        for branch in branches {
            lookup[branch.id] = branch
        }

        // Attach children to parents
        for branch in branches {
            if let parentId = branch.parentBranchId, lookup[parentId] != nil {
                lookup[parentId]!.children.append(branch)
            }
        }

        // Return root branches (no parent)
        return branches
            .filter { $0.parentBranchId == nil }
            .map { lookup[$0.id]! }
    }
}
