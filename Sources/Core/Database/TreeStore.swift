import Foundation
import GRDB

/// Returns a comma-separated list of `?` placeholders for SQL IN clauses.
private func sqlPlaceholders(count: Int) -> String {
    repeatElement("?", count: count).joined(separator: ", ")
}

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

    func getTrees(includeArchived: Bool = false) throws -> [ConversationTree] {
        try db.read { db in
            let archiveFilter = includeArchived ? "" : "WHERE t.archived = 0"
            let sql = """
                SELECT t.*,
                    COALESCE(msg_agg.message_count, 0) as message_count,
                    COALESCE(br_agg.branch_count, 0) as branch_count,
                    last_msg.content as last_message_snippet,
                    msg_agg.last_message_at as last_message_at
                FROM canvas_trees t
                LEFT JOIN (
                    SELECT b.tree_id, COUNT(m.id) as message_count, MAX(m.timestamp) as last_message_at
                    FROM canvas_branches b
                    JOIN messages m ON m.session_id = b.session_id
                    GROUP BY b.tree_id
                ) msg_agg ON msg_agg.tree_id = t.id
                LEFT JOIN (
                    SELECT tree_id, COUNT(*) as branch_count
                    FROM canvas_branches
                    WHERE status = 'active'
                    GROUP BY tree_id
                ) br_agg ON br_agg.tree_id = t.id
                LEFT JOIN (
                    SELECT b.tree_id, m.content
                    FROM messages m
                    JOIN canvas_branches b ON m.session_id = b.session_id
                    WHERE m.role = 'assistant'
                    GROUP BY b.tree_id
                    HAVING m.timestamp = MAX(m.timestamp)
                ) last_msg ON last_msg.tree_id = t.id
                \(archiveFilter)
                ORDER BY COALESCE(msg_agg.last_message_at, t.updated_at) DESC
                """

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

            var branches = try Branch.filter(Column("tree_id") == id)
                .order(Column("created_at"))
                .fetchAll(db)

            // Populate message counts in one bulk query
            let countRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT b.id, COUNT(m.id) as msg_count
                    FROM canvas_branches b
                    LEFT JOIN messages m ON m.session_id = b.session_id
                    WHERE b.tree_id = ?
                    GROUP BY b.id
                    """,
                arguments: [id]
            )
            var messageCounts: [String: Int] = [:]
            for row in countRows {
                if let branchId: String = row["id"] {
                    messageCounts[branchId] = row["msg_count"] ?? 0
                }
            }
            for index in branches.indices {
                branches[index].messageCount = messageCounts[branches[index].id] ?? 0
            }

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
            if projectName == AppConstants.defaultProjectName {
                // "General" encompasses trees with NULL, empty, or literal 'General' project
                try db.execute(
                    sql: "UPDATE canvas_trees SET archived = 1, updated_at = datetime('now') WHERE project IS NULL OR project = '' OR project = 'General'"
                )
            } else {
                try db.execute(
                    sql: "UPDATE canvas_trees SET archived = 1, updated_at = datetime('now') WHERE project = ?",
                    arguments: [projectName]
                )
            }
        }
    }

    /// Delete all trees in a project group (full cascade: messages → sessions → branches → trees).
    /// All deletes run in a single transaction — atomic.
    func deleteProject(_ projectName: String) throws {
        try db.write { db in
            let rows: [Row]
            if projectName == AppConstants.defaultProjectName {
                rows = try Row.fetchAll(db, sql: "SELECT id FROM canvas_trees WHERE project IS NULL OR project = '' OR project = 'General'")
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT id FROM canvas_trees WHERE project = ?", arguments: [projectName])
            }
            for row in rows {
                let id: String = row["id"]
                try Self.deleteTreeContents(db: db, treeId: id)
            }
        }
    }

    func deleteTree(_ id: String) throws {
        try db.write { db in
            try Self.deleteTreeContents(db: db, treeId: id)
        }
    }

    /// Executes the cascade delete for a single tree inside an already-open GRDB write transaction.
    /// FK-safe order: dependent tables → messages → canvas_branches → sessions → canvas_trees
    private static func deleteTreeContents(db: Database, treeId: String) throws {
        // Collect branch IDs and session IDs before any deletes
        let branchRows = try Row.fetchAll(
            db,
            sql: "SELECT id, session_id FROM canvas_branches WHERE tree_id = ?",
            arguments: [treeId]
        )
        let branchIds: [String] = branchRows.compactMap { $0["id"] }
        let sessionIds: [String] = branchRows.compactMap { $0["session_id"] }

        // 1. Delete from tables that reference branch_id or session_id
        //    These must go first while the IDs still exist in canvas_branches.
        if !branchIds.isEmpty {
            let branchPlaceholders = sqlPlaceholders(count: branchIds.count)
            let branchArgs = StatementArguments(branchIds)

            try db.execute(
                sql: "DELETE FROM canvas_token_usage WHERE branch_id IN (\(branchPlaceholders))",
                arguments: branchArgs
            )
            try db.execute(
                sql: "DELETE FROM canvas_events WHERE branch_id IN (\(branchPlaceholders))",
                arguments: branchArgs
            )
            try db.execute(
                sql: "DELETE FROM canvas_context_checkpoints WHERE branch_id IN (\(branchPlaceholders))",
                arguments: branchArgs
            )
            try db.execute(
                sql: "DELETE FROM canvas_screenshots WHERE branch_id IN (\(branchPlaceholders))",
                arguments: branchArgs
            )
            try db.execute(
                sql: "DELETE FROM canvas_dispatches WHERE branch_id IN (\(branchPlaceholders))",
                arguments: branchArgs
            )
        }

        if !sessionIds.isEmpty {
            let sessionPlaceholders = sqlPlaceholders(count: sessionIds.count)
            let sessionArgs = StatementArguments(sessionIds)

            try db.execute(
                sql: "DELETE FROM canvas_cli_sessions WHERE canvas_session_id IN (\(sessionPlaceholders))",
                arguments: sessionArgs
            )
        }

        // 2. Delete messages (references sessions via session_id)
        if !sessionIds.isEmpty {
            let placeholders = sqlPlaceholders(count: sessionIds.count)
            try db.execute(
                sql: "DELETE FROM messages WHERE session_id IN (\(placeholders))",
                arguments: StatementArguments(sessionIds)
            )
        }

        // 3. Delete canvas_branches (references sessions and canvas_trees)
        //    This also fires cascade triggers for canvas_branch_tags and canvas_api_state.
        try db.execute(sql: "DELETE FROM canvas_branches WHERE tree_id = ?", arguments: [treeId])

        // 4. Delete sessions (now safe — no branches reference them)
        if !sessionIds.isEmpty {
            let placeholders = sqlPlaceholders(count: sessionIds.count)
            try db.execute(
                sql: "DELETE FROM sessions WHERE id IN (\(placeholders))",
                arguments: StatementArguments(sessionIds)
            )
        }

        // 5. Delete the tree (now safe — no branches reference it)
        try db.execute(sql: "DELETE FROM canvas_trees WHERE id = ?", arguments: [treeId])
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
                arguments: [sessionId, "canvas", cwd, title ?? "World Tree branch"]
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

    /// Delete a single branch and its associated session/messages.
    /// Children are reparented to the deleted branch's parent (or become root branches).
    func deleteBranch(_ id: String) throws {
        try db.write { db in
            // Reparent children so they aren't orphaned
            let parentRow = try Row.fetchOne(
                db,
                sql: "SELECT parent_branch_id FROM canvas_branches WHERE id = ?",
                arguments: [id]
            )
            let parentId: String? = parentRow?["parent_branch_id"]
            if let parentId {
                try db.execute(
                    sql: "UPDATE canvas_branches SET parent_branch_id = ? WHERE parent_branch_id = ?",
                    arguments: [parentId, id]
                )
            } else {
                try db.execute(
                    sql: "UPDATE canvas_branches SET parent_branch_id = NULL WHERE parent_branch_id = ?",
                    arguments: [id]
                )
            }

            // Capture session_id before any deletes (FK-safe order)
            let sessionId: String? = try String.fetchOne(
                db,
                sql: "SELECT session_id FROM canvas_branches WHERE id = ?",
                arguments: [id]
            )

            // Delete from dependent tables that reference branch_id or session_id
            try db.execute(
                sql: "DELETE FROM canvas_token_usage WHERE branch_id = ?",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM canvas_events WHERE branch_id = ?",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM canvas_context_checkpoints WHERE branch_id = ?",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM canvas_screenshots WHERE branch_id = ?",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM canvas_dispatches WHERE branch_id = ?",
                arguments: [id]
            )
            if let sessionId {
                try db.execute(
                    sql: "DELETE FROM canvas_cli_sessions WHERE canvas_session_id = ?",
                    arguments: [sessionId]
                )
            }

            // Delete messages for this branch's session
            if let sessionId {
                try db.execute(
                    sql: "DELETE FROM messages WHERE session_id = ?",
                    arguments: [sessionId]
                )
            }

            // Delete the branch (fires cascade triggers for canvas_branch_tags + canvas_api_state)
            try db.execute(sql: "DELETE FROM canvas_branches WHERE id = ?", arguments: [id])

            // Delete the session (now safe — no branches reference it)
            if let sessionId {
                try db.execute(
                    sql: "DELETE FROM sessions WHERE id = ?",
                    arguments: [sessionId]
                )
            }
        }
    }

    /// Returns branches that fork from a specific message
    func getBranches(fromMessage messageId: Int) throws -> [Branch] {
        try db.read { db in
            try Branch.filter(Column("fork_from_message_id") == messageId).fetchAll(db)
        }
    }

    /// Push a message from a child branch up to the parent as a Finding.
    /// The finding is inserted into the parent session with a distinct prefix so
    /// DocumentEditorView can style it differently (purple border, system author).
    func inferFinding(fromBranchId: String, messageId: String, toParentBranchId: String) throws {
        // Load source branch + message
        guard let sourceBranch = try getBranch(fromBranchId),
              let sourceSessionId = sourceBranch.sessionId else { return }

        let messages = try MessageStore.shared.getMessages(sessionId: sourceSessionId)
        guard let message = messages.first(where: { $0.id == messageId }) else { return }

        // Load parent branch session
        guard let parentBranch = try getBranch(toParentBranchId),
              let parentSessionId = parentBranch.sessionId else { return }

        let branchLabel = sourceBranch.title ?? sourceBranch.displayTitle
        let findingContent = """
            [Finding from branch '\(branchLabel)']
            \(message.content)
            [End finding]
            """

        _ = try MessageStore.shared.sendMessage(
            sessionId: parentSessionId,
            role: .assistant,
            content: findingContent
        )
    }

    /// Find the branch whose associated session_id matches the given ID.
    /// Used by WorldTreeServer to resume a conversation from an external client.
    func getBranchBySessionId(_ sessionId: String) throws -> Branch? {
        try db.read { db in
            try Branch.filter(Column("session_id") == sessionId).fetchOne(db)
        }
    }

    /// Batch-fetch branches by session IDs in a single IN query.
    /// Returns a dictionary keyed by session_id for O(1) lookup.
    func getBranchesBySessionIds(_ sessionIds: [String]) throws -> [String: Branch] {
        guard !sessionIds.isEmpty else { return [:] }
        return try db.read { db in
            let placeholders = sqlPlaceholders(count: sessionIds.count)
            let sql = "SELECT * FROM canvas_branches WHERE session_id IN (\(placeholders))"
            let args = StatementArguments(sessionIds)
            let branches = try Branch.fetchAll(db, sql: sql, arguments: args)
            return Dictionary(uniqueKeysWithValues: branches.compactMap { branch in
                guard let sid = branch.sessionId else { return nil }
                return (sid, branch)
            })
        }
    }

    /// Batch-fetch branches grouped by tree ID in a single IN query.
    /// Returns a dictionary keyed by tree_id for O(1) lookup per tree.
    func getBranchesByTreeIds(_ treeIds: [String]) throws -> [String: [Branch]] {
        guard !treeIds.isEmpty else { return [:] }
        return try db.read { db in
            let placeholders = sqlPlaceholders(count: treeIds.count)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM canvas_branches WHERE tree_id IN (\(placeholders)) ORDER BY created_at",
                arguments: StatementArguments(treeIds)
            )
            var result: [String: [Branch]] = [:]
            for row in rows {
                let branch = Branch(row: row)
                result[branch.treeId, default: []].append(branch)
            }
            return result
        }
    }

    // MARK: - Branch Navigation

    /// Returns the path from the root branch to the given branch (inclusive).
    /// Uses a recursive CTE instead of loading every branch in the tree.
    func getBranchPath(to branchId: String) throws -> [Branch] {
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

    /// Builds a tree hierarchy from a flat list of branches.
    /// Uses a two-pass recursive approach to correctly nest grandchildren
    /// and compute depth for each branch.
    static func buildBranchTree(from branches: [Branch]) -> [Branch] {
        guard !branches.isEmpty else { return [] }

        // Build O(1) parent lookup — avoids O(n) scan per depth computation
        let parentLookup: [String: String?] = Dictionary(
            uniqueKeysWithValues: branches.map { ($0.id, $0.parentBranchId) }
        )

        // Pass 1: compute depth by walking each branch's parent chain
        var depthCache: [String: Int] = [:]
        func computeDepth(id: String) -> Int {
            if let d = depthCache[id] { return d }
            let parent = parentLookup[id] ?? nil
            let d = parent.map { computeDepth(id: $0) + 1 } ?? 0
            depthCache[id] = d
            return d
        }
        branches.forEach { _ = computeDepth(id: $0.id) }

        // Build lookup with depth stamped in
        var lookup: [String: Branch] = [:]
        for var branch in branches {
            branch.depth = depthCache[branch.id] ?? 0
            lookup[branch.id] = branch
        }

        // Build children-IDs map
        var childrenIds: [String: [String]] = [:]
        for branch in branches {
            if let parentId = branch.parentBranchId {
                childrenIds[parentId, default: []].append(branch.id)
            }
        }

        // Pass 2: recursively attach children (fixes struct value-type grandchild bug)
        func attachChildren(to branchId: String) -> Branch? {
            guard var branch = lookup[branchId] else { return nil }
            branch.children = (childrenIds[branchId] ?? []).compactMap { attachChildren(to: $0) }
            return branch
        }

        return branches
            .filter { $0.parentBranchId == nil }
            .compactMap { attachChildren(to: $0.id) }
    }
}
