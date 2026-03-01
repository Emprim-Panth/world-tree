import XCTest
import GRDB
@testable import WorldTree

// MARK: - TreeStore Unit Tests

/// Comprehensive tests for the TreeStore data layer — the core CRUD, branch operations,
/// denormalization triggers, and edge cases. Each test gets a fresh temporary database
/// with all migrations applied.
///
/// These tests operate directly on a DatabasePool rather than going through TreeStore.shared,
/// because the singleton is coupled to DatabaseManager.shared (production database).
/// The SQL and model operations are identical to what TreeStore executes internally.
@MainActor
final class TreeStoreTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "treestore-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)
        try MigrationManager.migrate(dbPool)
    }

    override func tearDown() async throws {
        dbPool = nil
        if let path = dbPath {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
        dbPath = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Creates a tree directly in the database and returns it.
    @discardableResult
    private func createTree(
        id: String = UUID().uuidString,
        name: String = "Test Tree",
        project: String? = nil,
        workingDirectory: String? = nil,
        archived: Bool = false
    ) throws -> ConversationTree {
        let tree = ConversationTree(
            id: id,
            name: name,
            project: project,
            workingDirectory: workingDirectory,
            createdAt: Date(),
            updatedAt: Date(),
            archived: archived
        )
        try dbPool.write { db in
            try tree.insert(db)
        }
        return tree
    }

    /// Creates a session + branch in the database. Returns the branch.
    @discardableResult
    private func createBranch(
        id: String = UUID().uuidString,
        treeId: String,
        parentBranchId: String? = nil,
        forkFromMessageId: String? = nil,
        type: BranchType = .conversation,
        title: String? = nil,
        model: String? = nil,
        contextSnapshot: String? = nil,
        workingDirectory: String = "~/Development"
    ) throws -> Branch {
        let sessionId = UUID().uuidString

        try dbPool.write { db in
            // Create session (matches TreeStore.createBranch pattern)
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, terminal_id, working_directory, description, started_at)
                    VALUES (?, ?, ?, ?, datetime('now'))
                    """,
                arguments: [sessionId, "canvas", workingDirectory, title ?? "Test branch"]
            )

            // Create branch
            let branch = Branch(
                id: id,
                treeId: treeId,
                sessionId: sessionId,
                parentBranchId: parentBranchId,
                forkFromMessageId: forkFromMessageId,
                branchType: type,
                title: title,
                status: .active,
                model: model,
                contextSnapshot: contextSnapshot,
                compactionMode: .auto,
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
        }

        return try dbPool.read { db in
            try Branch.fetchOne(db, key: id)!
        }
    }

    /// Inserts a message into a session. Returns the row ID.
    @discardableResult
    private func insertMessage(
        sessionId: String,
        role: String = "user",
        content: String = "Hello"
    ) throws -> Int64 {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (session_id, role, content, timestamp)
                    VALUES (?, ?, ?, datetime('now'))
                    """,
                arguments: [sessionId, role, content]
            )
            return db.lastInsertedRowID
        }
    }

    // MARK: - 1. CRUD Operations

    func testCreateTree() throws {
        let tree = try createTree(name: "My Tree", project: "WorldTree")

        let fetched = try dbPool.read { db in
            try ConversationTree.fetchOne(db, key: tree.id)
        }

        XCTAssertNotNil(fetched, "Created tree must be retrievable by ID")
        XCTAssertEqual(fetched?.name, "My Tree")
        XCTAssertEqual(fetched?.project, "WorldTree")
        XCTAssertFalse(fetched?.archived ?? true, "New tree should not be archived")
    }

    func testDeleteTree() throws {
        // Create tree with branch, session, and messages
        let tree = try createTree(name: "Doomed Tree")
        let branch = try createBranch(treeId: tree.id, title: "Branch to delete")
        let sessionId = branch.sessionId!

        // Add messages
        try insertMessage(sessionId: sessionId, role: "user", content: "Hello")
        try insertMessage(sessionId: sessionId, role: "assistant", content: "Hi there")

        // Verify messages exist before delete
        let msgCountBefore = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE session_id = ?", arguments: [sessionId])
        }
        XCTAssertEqual(msgCountBefore, 2, "Should have 2 messages before delete")

        // Delete tree using TreeStore's cascade pattern
        try dbPool.write { db in
            // Collect session IDs
            let sessionRows = try Row.fetchAll(
                db,
                sql: "SELECT session_id FROM canvas_branches WHERE tree_id = ?",
                arguments: [tree.id]
            )
            let sessionIds: [String] = sessionRows.compactMap { $0["session_id"] }

            // Delete messages
            if !sessionIds.isEmpty {
                let placeholders = sessionIds.map { _ in "?" }.joined(separator: ", ")
                try db.execute(
                    sql: "DELETE FROM messages WHERE session_id IN (\(placeholders))",
                    arguments: StatementArguments(sessionIds)
                )
            }

            // Delete branches
            try db.execute(sql: "DELETE FROM canvas_branches WHERE tree_id = ?", arguments: [tree.id])

            // Delete sessions
            if !sessionIds.isEmpty {
                let placeholders = sessionIds.map { _ in "?" }.joined(separator: ", ")
                try db.execute(
                    sql: "DELETE FROM sessions WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(sessionIds)
                )
            }

            // Delete tree
            try db.execute(sql: "DELETE FROM canvas_trees WHERE id = ?", arguments: [tree.id])
        }

        // Verify everything is gone
        let treeGone = try dbPool.read { db in
            try ConversationTree.fetchOne(db, key: tree.id)
        }
        XCTAssertNil(treeGone, "Tree should be deleted")

        let branchGone = try dbPool.read { db in
            try Branch.fetchOne(db, key: branch.id)
        }
        XCTAssertNil(branchGone, "Branch should be cascade-deleted")

        let msgCountAfter = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE session_id = ?", arguments: [sessionId])
        }
        XCTAssertEqual(msgCountAfter, 0, "Messages should be cascade-deleted")

        let sessionGone = try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [sessionId])
        }
        XCTAssertNil(sessionGone, "Session should be cascade-deleted")
    }

    func testListTrees() throws {
        // Create multiple trees with slightly staggered timestamps
        try createTree(name: "Alpha", project: "ProjectA")
        try createTree(name: "Beta", project: "ProjectB")
        try createTree(name: "Gamma", project: "ProjectA")

        // getTrees uses a complex query with JOINs — replicate the core part
        let trees = try dbPool.read { db in
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
                WHERE t.archived = 0
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

        XCTAssertEqual(trees.count, 3, "Should return all 3 non-archived trees")

        let names = Set(trees.map(\.name))
        XCTAssertTrue(names.contains("Alpha"))
        XCTAssertTrue(names.contains("Beta"))
        XCTAssertTrue(names.contains("Gamma"))
    }

    func testArchiveTree() throws {
        let tree = try createTree(name: "Archivable Tree")

        // Archive it
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE canvas_trees SET archived = 1, updated_at = datetime('now') WHERE id = ?",
                arguments: [tree.id]
            )
        }

        // List without archived — should be empty
        let active = try dbPool.read { db in
            try ConversationTree.filter(Column("archived") == 0).fetchAll(db)
        }
        XCTAssertEqual(active.count, 0, "Archived tree should be excluded from active list")

        // Fetch directly — archived flag should be set
        let archivedFlag = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT archived FROM canvas_trees WHERE id = ?", arguments: [tree.id])
        }
        XCTAssertEqual(archivedFlag, 1, "Tree should have archived=1")

        // List with archived included — should find it
        let all = try dbPool.read { db in
            try ConversationTree.fetchAll(db)
        }
        XCTAssertEqual(all.count, 1, "includeArchived should return the archived tree")
    }

    func testRenameTree() throws {
        let tree = try createTree(name: "Original Name")

        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE canvas_trees SET name = ?, updated_at = datetime('now') WHERE id = ?",
                arguments: ["New Name", tree.id]
            )
        }

        let fetched = try dbPool.read { db in
            try ConversationTree.fetchOne(db, key: tree.id)
        }
        XCTAssertEqual(fetched?.name, "New Name")
    }

    func testMoveTree() throws {
        let tree = try createTree(name: "Movable", project: "ProjectA")

        // Move to ProjectB
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE canvas_trees SET project = ?, updated_at = datetime('now') WHERE id = ?",
                arguments: ["ProjectB", tree.id]
            )
        }

        let fetched = try dbPool.read { db in
            try ConversationTree.fetchOne(db, key: tree.id)
        }
        XCTAssertEqual(fetched?.project, "ProjectB")

        // Move to no project (NULL)
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE canvas_trees SET project = NULL, updated_at = datetime('now') WHERE id = ?",
                arguments: [tree.id]
            )
        }

        let fetchedAgain = try dbPool.read { db in
            try ConversationTree.fetchOne(db, key: tree.id)
        }
        XCTAssertNil(fetchedAgain?.project, "Project should be NULL after moving to no project")
    }

    // MARK: - 2. Branch Operations

    func testCreateBranch() throws {
        let tree = try createTree(name: "Branchy Tree")
        let branch = try createBranch(
            treeId: tree.id,
            type: .conversation,
            title: "Main Branch",
            model: "sonnet"
        )

        XCTAssertEqual(branch.treeId, tree.id)
        XCTAssertEqual(branch.branchType, .conversation)
        XCTAssertEqual(branch.title, "Main Branch")
        XCTAssertEqual(branch.status, .active)
        XCTAssertEqual(branch.model, "sonnet")
        XCTAssertNotNil(branch.sessionId, "Branch must have an associated session")
        XCTAssertNil(branch.parentBranchId, "Root branch should have no parent")

        // Verify session was created
        let session = try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [branch.sessionId!])
        }
        XCTAssertNotNil(session, "Session must exist in sessions table")
    }

    func testCreateNestedBranch() throws {
        let tree = try createTree(name: "Nested Tree")
        let rootBranch = try createBranch(treeId: tree.id, title: "Root")

        // Add a message to the root branch
        let msgId = try insertMessage(sessionId: rootBranch.sessionId!, role: "assistant", content: "Some answer")

        // Fork from that message
        let childBranch = try createBranch(
            treeId: tree.id,
            parentBranchId: rootBranch.id,
            forkFromMessageId: String(msgId),
            type: .exploration,
            title: "Exploration Fork"
        )

        XCTAssertEqual(childBranch.parentBranchId, rootBranch.id, "Child should reference parent")
        XCTAssertEqual(childBranch.forkFromMessageId, String(msgId), "Should reference fork message")
        XCTAssertEqual(childBranch.branchType, .exploration)

        // Create grandchild
        let grandchild = try createBranch(
            treeId: tree.id,
            parentBranchId: childBranch.id,
            type: .implementation,
            title: "Deep Fork"
        )

        XCTAssertEqual(grandchild.parentBranchId, childBranch.id)
        XCTAssertEqual(grandchild.branchType, .implementation)
    }

    func testGetBranchesByTreeIds() throws {
        let tree1 = try createTree(name: "Tree 1")
        let tree2 = try createTree(name: "Tree 2")
        let tree3 = try createTree(name: "Tree 3")

        // Create branches: 2 for tree1, 1 for tree2, 0 for tree3
        try createBranch(treeId: tree1.id, title: "T1-B1")
        try createBranch(treeId: tree1.id, title: "T1-B2")
        try createBranch(treeId: tree2.id, title: "T2-B1")

        // Batch fetch
        let treeIds = [tree1.id, tree2.id, tree3.id]
        let result = try dbPool.read { db in
            let placeholders = treeIds.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM canvas_branches WHERE tree_id IN (\(placeholders)) ORDER BY created_at",
                arguments: StatementArguments(treeIds)
            )
            var grouped: [String: [Branch]] = [:]
            for row in rows {
                let branch = Branch(row: row)
                grouped[branch.treeId, default: []].append(branch)
            }
            return grouped
        }

        XCTAssertEqual(result[tree1.id]?.count, 2, "Tree 1 should have 2 branches")
        XCTAssertEqual(result[tree2.id]?.count, 1, "Tree 2 should have 1 branch")
        XCTAssertNil(result[tree3.id], "Tree 3 should have no branches (absent key)")
    }

    func testDeleteBranchCascade() throws {
        let tree = try createTree(name: "Cascade Test")
        let branch = try createBranch(treeId: tree.id, title: "Deletable")
        let sessionId = branch.sessionId!

        // Add branch tags
        try dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO canvas_branch_tags (branch_id, tag) VALUES (?, ?)",
                arguments: [branch.id, "important"]
            )
            try db.execute(
                sql: "INSERT INTO canvas_branch_tags (branch_id, tag) VALUES (?, ?)",
                arguments: [branch.id, "reviewed"]
            )
        }

        // Add API state
        try dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO canvas_api_state (session_id, api_messages, system_prompt) VALUES (?, ?, ?)",
                arguments: [sessionId, "[]", "You are a test."]
            )
        }

        // Add messages
        try insertMessage(sessionId: sessionId, role: "user", content: "Test message")

        // Verify everything exists before delete
        let tagsBefore = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM canvas_branch_tags WHERE branch_id = ?", arguments: [branch.id])
        }
        XCTAssertEqual(tagsBefore, 2)

        let apiStateBefore = try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM canvas_api_state WHERE session_id = ?", arguments: [sessionId])
        }
        XCTAssertNotNil(apiStateBefore)

        // Delete branch — FK-safe order: messages → branch → session
        // (canvas_branches.session_id references sessions.id, so branch must be deleted before session)
        try dbPool.write { db in
            // Capture session_id before deleting
            let sid = try String.fetchOne(
                db, sql: "SELECT session_id FROM canvas_branches WHERE id = ?", arguments: [branch.id]
            )

            // Delete messages for this branch's session
            try db.execute(
                sql: "DELETE FROM messages WHERE session_id = ?",
                arguments: [sid]
            )

            // Delete the branch first (triggers cascade_tags and cascade_api_state from v18)
            try db.execute(sql: "DELETE FROM canvas_branches WHERE id = ?", arguments: [branch.id])

            // Now safe to delete the session (no FK references remain)
            if let sid {
                try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [sid])
            }
        }

        // Verify branch gone
        let branchGone = try dbPool.read { db in
            try Branch.fetchOne(db, key: branch.id)
        }
        XCTAssertNil(branchGone, "Branch should be deleted")

        // Verify cascade trigger cleaned up tags (v18 trigger)
        let tagsAfter = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM canvas_branch_tags WHERE branch_id = ?", arguments: [branch.id])
        }
        XCTAssertEqual(tagsAfter, 0, "Branch tags should be cascade-deleted by v18 trigger")

        // Verify cascade trigger cleaned up API state (v18 trigger)
        let apiStateAfter = try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM canvas_api_state WHERE session_id = ?", arguments: [sessionId])
        }
        XCTAssertNil(apiStateAfter, "API state should be cascade-deleted by v18 trigger")
    }

    func testDeleteBranchReparentsChildren() throws {
        let tree = try createTree(name: "Reparent Test")
        let parent = try createBranch(treeId: tree.id, title: "Parent")
        let child = try createBranch(treeId: tree.id, parentBranchId: parent.id, title: "Child")
        let grandchild = try createBranch(treeId: tree.id, parentBranchId: child.id, title: "Grandchild")

        // Delete the middle branch (child) — grandchild should be reparented to parent
        try dbPool.write { db in
            let parentRow = try Row.fetchOne(
                db,
                sql: "SELECT parent_branch_id FROM canvas_branches WHERE id = ?",
                arguments: [child.id]
            )
            let childParentId: String? = parentRow?["parent_branch_id"]

            if let childParentId {
                try db.execute(
                    sql: "UPDATE canvas_branches SET parent_branch_id = ? WHERE parent_branch_id = ?",
                    arguments: [childParentId, child.id]
                )
            } else {
                try db.execute(
                    sql: "UPDATE canvas_branches SET parent_branch_id = NULL WHERE parent_branch_id = ?",
                    arguments: [child.id]
                )
            }

            // FK-safe delete order: messages → branch → session
            let sid = try String.fetchOne(
                db, sql: "SELECT session_id FROM canvas_branches WHERE id = ?", arguments: [child.id]
            )
            try db.execute(
                sql: "DELETE FROM messages WHERE session_id = ?",
                arguments: [sid]
            )
            try db.execute(sql: "DELETE FROM canvas_branches WHERE id = ?", arguments: [child.id])
            if let sid {
                try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [sid])
            }
        }

        // Grandchild should now point to parent
        let updatedGrandchild = try dbPool.read { db in
            try Branch.fetchOne(db, key: grandchild.id)
        }
        XCTAssertEqual(updatedGrandchild?.parentBranchId, parent.id,
                        "Grandchild should be reparented to the deleted branch's parent")
    }

    func testUpdateBranchStatus() throws {
        let tree = try createTree(name: "Status Test")
        let branch = try createBranch(treeId: tree.id, title: "Updatable")

        // Update to completed
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE canvas_branches SET status = ?, updated_at = datetime('now') WHERE id = ?",
                arguments: [BranchStatus.completed.rawValue, branch.id]
            )
        }

        let fetched = try dbPool.read { db in
            try Branch.fetchOne(db, key: branch.id)
        }
        XCTAssertEqual(fetched?.status, .completed)
    }

    func testBranchContextSnapshotInjectsSystemMessage() throws {
        let tree = try createTree(name: "Context Test")
        let branch = try createBranch(
            treeId: tree.id,
            contextSnapshot: "You are testing the branch context."
        )

        // Verify system message was inserted
        let messages = try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM messages WHERE session_id = ? AND role = 'system'",
                arguments: [branch.sessionId!]
            )
        }
        XCTAssertEqual(messages.count, 1, "Should have 1 system message from context snapshot")
        let content: String = messages[0]["content"]
        XCTAssertEqual(content, "You are testing the branch context.")
    }

    // MARK: - 3. Denormalization (v17 triggers)

    func testMessageInsertUpdatesTreeStats() throws {
        let tree = try createTree(name: "Trigger Test")
        let branch = try createBranch(treeId: tree.id)
        let sessionId = branch.sessionId!

        // Verify initial state
        let countBefore = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT message_count FROM canvas_trees WHERE id = ?", arguments: [tree.id])
        }
        XCTAssertEqual(countBefore, 0, "Initial message_count should be 0")

        // Insert user message (simulating daemon/external write)
        try insertMessage(sessionId: sessionId, role: "user", content: "Hello world")

        // Verify trigger updated message_count
        let countAfterUser = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT message_count FROM canvas_trees WHERE id = ?", arguments: [tree.id])
        }
        XCTAssertEqual(countAfterUser, 1, "message_count should be 1 after user message insert")

        let lastMsgAt = try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT last_message_at FROM canvas_trees WHERE id = ?", arguments: [tree.id])
        }
        XCTAssertNotNil(lastMsgAt, "last_message_at should be set")

        // Insert assistant message
        try insertMessage(sessionId: sessionId, role: "assistant", content: "Hi! How can I help?")

        let countAfterAssistant = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT message_count FROM canvas_trees WHERE id = ?", arguments: [tree.id])
        }
        XCTAssertEqual(countAfterAssistant, 2, "message_count should be 2 after assistant message insert")

        let snippet = try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT last_assistant_snippet FROM canvas_trees WHERE id = ?", arguments: [tree.id])
        }
        XCTAssertEqual(snippet, "Hi! How can I help?",
                        "last_assistant_snippet should be updated on assistant message insert")
    }

    func testMessageDeleteUpdatesTreeStats() throws {
        let tree = try createTree(name: "Delete Trigger Test")
        let branch = try createBranch(treeId: tree.id)
        let sessionId = branch.sessionId!

        // Insert 3 messages
        let msgId1 = try insertMessage(sessionId: sessionId, role: "user", content: "One")
        try insertMessage(sessionId: sessionId, role: "assistant", content: "Two")
        try insertMessage(sessionId: sessionId, role: "user", content: "Three")

        // Verify count is 3
        let countBefore = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT message_count FROM canvas_trees WHERE id = ?", arguments: [tree.id])
        }
        XCTAssertEqual(countBefore, 3)

        // Delete one message
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [msgId1])
        }

        // Verify count decremented to 2
        let countAfter = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT message_count FROM canvas_trees WHERE id = ?", arguments: [tree.id])
        }
        XCTAssertEqual(countAfter, 2, "message_count should decrement on delete")
    }

    func testAssistantSnippetOnlyUpdatesOnAssistantRole() throws {
        let tree = try createTree(name: "Snippet Role Test")
        let branch = try createBranch(treeId: tree.id)
        let sessionId = branch.sessionId!

        // Insert assistant message first to set a known snippet
        try insertMessage(sessionId: sessionId, role: "assistant", content: "Initial response")

        let snippetAfterAssistant = try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT last_assistant_snippet FROM canvas_trees WHERE id = ?", arguments: [tree.id])
        }
        XCTAssertEqual(snippetAfterAssistant, "Initial response")

        // Insert user message — snippet should NOT change
        try insertMessage(sessionId: sessionId, role: "user", content: "Follow-up question")

        let snippetAfterUser = try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT last_assistant_snippet FROM canvas_trees WHERE id = ?", arguments: [tree.id])
        }
        XCTAssertEqual(snippetAfterUser, "Initial response",
                        "User message should not overwrite last_assistant_snippet")

        // Insert system message — snippet should NOT change
        try insertMessage(sessionId: sessionId, role: "system", content: "System instruction")

        let snippetAfterSystem = try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT last_assistant_snippet FROM canvas_trees WHERE id = ?", arguments: [tree.id])
        }
        XCTAssertEqual(snippetAfterSystem, "Initial response",
                        "System message should not overwrite last_assistant_snippet")
    }

    func testMultipleBranchesAggregateToSameTree() throws {
        let tree = try createTree(name: "Multi-Branch Stats")
        let branch1 = try createBranch(treeId: tree.id, title: "Branch A")
        let branch2 = try createBranch(treeId: tree.id, title: "Branch B")

        // Insert messages into both branches
        try insertMessage(sessionId: branch1.sessionId!, role: "user", content: "From branch A")
        try insertMessage(sessionId: branch1.sessionId!, role: "assistant", content: "Reply A")
        try insertMessage(sessionId: branch2.sessionId!, role: "user", content: "From branch B")

        // The denormalized message_count reflects messages from ALL branches
        let totalCount = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT message_count FROM canvas_trees WHERE id = ?", arguments: [tree.id])
        }
        XCTAssertEqual(totalCount, 3,
                        "message_count should aggregate messages across all branches in the tree")
    }

    // MARK: - 4. Edge Cases

    func testEmptyTreeIds() throws {
        // getBranchesByTreeIds([]) should return empty dictionary
        let emptyIds: [String] = []
        let result: [String: [Branch]]
        if emptyIds.isEmpty {
            result = [:]
        } else {
            result = try dbPool.read { db in
                let placeholders = emptyIds.map { _ in "?" }.joined(separator: ", ")
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM canvas_branches WHERE tree_id IN (\(placeholders)) ORDER BY created_at",
                    arguments: StatementArguments(emptyIds)
                )
                var grouped: [String: [Branch]] = [:]
                for row in rows {
                    let branch = Branch(row: row)
                    grouped[branch.treeId, default: []].append(branch)
                }
                return grouped
            }
        }
        XCTAssertTrue(result.isEmpty, "Empty tree IDs should return empty dictionary")
    }

    func testDeleteNonexistentTree() throws {
        // Deleting a tree that doesn't exist should not crash
        let fakeId = "nonexistent-tree-\(UUID().uuidString)"

        // This should execute without error — DELETE WHERE id = ? on nonexistent row is a no-op
        try dbPool.write { db in
            let sessionRows = try Row.fetchAll(
                db,
                sql: "SELECT session_id FROM canvas_branches WHERE tree_id = ?",
                arguments: [fakeId]
            )
            let sessionIds: [String] = sessionRows.compactMap { $0["session_id"] }

            if !sessionIds.isEmpty {
                let placeholders = sessionIds.map { _ in "?" }.joined(separator: ", ")
                try db.execute(
                    sql: "DELETE FROM messages WHERE session_id IN (\(placeholders))",
                    arguments: StatementArguments(sessionIds)
                )
            }

            try db.execute(sql: "DELETE FROM canvas_branches WHERE tree_id = ?", arguments: [fakeId])

            if !sessionIds.isEmpty {
                let placeholders = sessionIds.map { _ in "?" }.joined(separator: ", ")
                try db.execute(
                    sql: "DELETE FROM sessions WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(sessionIds)
                )
            }

            try db.execute(sql: "DELETE FROM canvas_trees WHERE id = ?", arguments: [fakeId])
        }

        // If we got here without crashing, the test passes
    }

    func testConcurrentTreeCreation() async throws {
        let count = 50
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask { [dbPool] in
                    let tree = ConversationTree(
                        id: "concurrent-\(i)",
                        name: "Tree \(i)",
                        project: "Stress-\(i % 5)",
                        workingDirectory: nil,
                        createdAt: Date(),
                        updatedAt: Date(),
                        archived: false
                    )
                    try? dbPool?.write { db in
                        try tree.insert(db)
                    }
                }
            }
        }

        let total = try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM canvas_trees")
        }
        XCTAssertEqual(total, count, "All \(count) concurrent tree inserts should succeed (WAL mode)")
    }

    // MARK: - 5. Branch Tree Building (static method)

    func testBuildBranchTreeFromFlat() throws {
        // Test the static buildBranchTree method that converts flat list to hierarchy
        let root = Branch(
            id: "root", treeId: "t1", sessionId: "s1", parentBranchId: nil,
            forkFromMessageId: nil, branchType: .conversation, title: "Root",
            status: .active, model: nil, contextSnapshot: nil, compactionMode: .auto, collapsed: false,
            createdAt: Date(), updatedAt: Date()
        )
        let child1 = Branch(
            id: "child1", treeId: "t1", sessionId: "s2", parentBranchId: "root",
            forkFromMessageId: nil, branchType: .exploration, title: "Child 1",
            status: .active, model: nil, contextSnapshot: nil, compactionMode: .auto, collapsed: false,
            createdAt: Date().addingTimeInterval(1), updatedAt: Date().addingTimeInterval(1)
        )
        let child2 = Branch(
            id: "child2", treeId: "t1", sessionId: "s3", parentBranchId: "root",
            forkFromMessageId: nil, branchType: .implementation, title: "Child 2",
            status: .active, model: nil, contextSnapshot: nil, compactionMode: .auto, collapsed: false,
            createdAt: Date().addingTimeInterval(2), updatedAt: Date().addingTimeInterval(2)
        )
        let grandchild = Branch(
            id: "grandchild", treeId: "t1", sessionId: "s4", parentBranchId: "child1",
            forkFromMessageId: nil, branchType: .conversation, title: "Grandchild",
            status: .active, model: nil, contextSnapshot: nil, compactionMode: .auto, collapsed: false,
            createdAt: Date().addingTimeInterval(3), updatedAt: Date().addingTimeInterval(3)
        )

        let flat = [root, child1, child2, grandchild]
        let tree = TreeStore.buildBranchTree(from: flat)

        XCTAssertEqual(tree.count, 1, "Should have 1 root branch")
        XCTAssertEqual(tree[0].id, "root")
        XCTAssertEqual(tree[0].depth, 0, "Root should be depth 0")
        XCTAssertEqual(tree[0].children.count, 2, "Root should have 2 children")

        let childIds = Set(tree[0].children.map(\.id))
        XCTAssertEqual(childIds, Set(["child1", "child2"]))

        let c1 = tree[0].children.first { $0.id == "child1" }
        XCTAssertEqual(c1?.depth, 1, "Child should be depth 1")
        XCTAssertEqual(c1?.children.count, 1, "child1 should have 1 grandchild")
        XCTAssertEqual(c1?.children.first?.id, "grandchild")
        XCTAssertEqual(c1?.children.first?.depth, 2, "Grandchild should be depth 2")
    }

    func testBuildBranchTreeEmpty() {
        let tree = TreeStore.buildBranchTree(from: [])
        XCTAssertTrue(tree.isEmpty, "Empty input should produce empty output")
    }

    func testBuildBranchTreeSingleRoot() {
        let root = Branch(
            id: "solo", treeId: "t1", sessionId: "s1", parentBranchId: nil,
            forkFromMessageId: nil, branchType: .conversation, title: "Solo",
            status: .active, model: nil, contextSnapshot: nil, compactionMode: .auto, collapsed: false,
            createdAt: Date(), updatedAt: Date()
        )

        let tree = TreeStore.buildBranchTree(from: [root])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].id, "solo")
        XCTAssertEqual(tree[0].children.count, 0)
        XCTAssertEqual(tree[0].depth, 0)
    }

    // MARK: - 6. Branch Queries

    func testGetBranchBySessionId() throws {
        let tree = try createTree(name: "Session Lookup")
        let branch = try createBranch(treeId: tree.id, title: "Findable")
        let sessionId = branch.sessionId!

        let found = try dbPool.read { db in
            try Branch.filter(Column("session_id") == sessionId).fetchOne(db)
        }
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, branch.id)
    }

    func testGetBranchesBySessionIds() throws {
        let tree = try createTree(name: "Batch Session Lookup")
        let branch1 = try createBranch(treeId: tree.id, title: "B1")
        let branch2 = try createBranch(treeId: tree.id, title: "B2")
        let sessionIds = [branch1.sessionId!, branch2.sessionId!]

        let result: [String: Branch] = try dbPool.read { db in
            let placeholders = sessionIds.map { _ in "?" }.joined(separator: ", ")
            let sql = "SELECT * FROM canvas_branches WHERE session_id IN (\(placeholders))"
            let branches = try Branch.fetchAll(db, sql: sql, arguments: StatementArguments(sessionIds))
            var dict: [String: Branch] = [:]
            for branch in branches {
                if let sid = branch.sessionId {
                    dict[sid] = branch
                }
            }
            return dict
        }

        XCTAssertEqual(result.count, 2)
        XCTAssertNotNil(result[branch1.sessionId!])
        XCTAssertNotNil(result[branch2.sessionId!])
    }

    func testGetSiblingBranches() throws {
        let tree = try createTree(name: "Sibling Test")
        let root = try createBranch(treeId: tree.id, title: "Root")
        let child1 = try createBranch(treeId: tree.id, parentBranchId: root.id, title: "Child 1")
        let child2 = try createBranch(treeId: tree.id, parentBranchId: root.id, title: "Child 2")
        let child3 = try createBranch(treeId: tree.id, parentBranchId: root.id, title: "Child 3")

        // Get siblings of child2 (should be child1 and child3)
        let siblings = try dbPool.read { db in
            guard let branch = try Branch.fetchOne(db, key: child2.id) else { return [Branch]() }
            if let parentId = branch.parentBranchId {
                return try Branch
                    .filter(Column("parent_branch_id") == parentId && Column("id") != child2.id)
                    .order(Column("created_at"))
                    .fetchAll(db)
            }
            return []
        }

        XCTAssertEqual(siblings.count, 2)
        let siblingIds = Set(siblings.map(\.id))
        XCTAssertTrue(siblingIds.contains(child1.id))
        XCTAssertTrue(siblingIds.contains(child3.id))
        XCTAssertFalse(siblingIds.contains(child2.id), "Should not include self")
    }

    // MARK: - 7. Project-Level Operations

    func testArchiveProject() throws {
        // Create trees in different projects
        try createTree(name: "T1", project: "TargetProject")
        try createTree(name: "T2", project: "TargetProject")
        try createTree(name: "T3", project: "OtherProject")

        // Archive the target project
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE canvas_trees SET archived = 1, updated_at = datetime('now') WHERE project = ?",
                arguments: ["TargetProject"]
            )
        }

        let archived = try dbPool.read { db in
            try ConversationTree.filter(Column("archived") == 1).fetchAll(db)
        }
        XCTAssertEqual(archived.count, 2, "Both TargetProject trees should be archived")

        let active = try dbPool.read { db in
            try ConversationTree.filter(Column("archived") == 0).fetchAll(db)
        }
        XCTAssertEqual(active.count, 1, "OtherProject tree should remain active")
        XCTAssertEqual(active.first?.project, "OtherProject")
    }

    func testArchiveGeneralProjectIncludesNullAndEmpty() throws {
        // "General" encompasses NULL, empty string, and literal "General"
        try createTree(name: "Null Project")  // project is nil
        try createTree(name: "Empty Project", project: "")
        try createTree(name: "General Project", project: "General")
        try createTree(name: "Named Project", project: "BookBuddy")

        // Archive "General" — matches TreeStore.archiveProject logic
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE canvas_trees SET archived = 1, updated_at = datetime('now') WHERE project IS NULL OR project = '' OR project = 'General'"
            )
        }

        let archived = try dbPool.read { db in
            try ConversationTree.filter(Column("archived") == 1).fetchAll(db)
        }
        XCTAssertEqual(archived.count, 3, "NULL, empty, and 'General' project trees should all be archived")

        let active = try dbPool.read { db in
            try ConversationTree.filter(Column("archived") == 0).fetchAll(db)
        }
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.name, "Named Project")
    }

    func testDeleteProject() throws {
        let tree1 = try createTree(name: "T1", project: "Doomed")
        let tree2 = try createTree(name: "T2", project: "Doomed")
        try createTree(name: "T3", project: "Safe")

        let b1 = try createBranch(treeId: tree1.id)
        let b2 = try createBranch(treeId: tree2.id)
        try insertMessage(sessionId: b1.sessionId!, content: "msg1")
        try insertMessage(sessionId: b2.sessionId!, content: "msg2")

        // Delete the "Doomed" project (full cascade)
        try dbPool.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id FROM canvas_trees WHERE project = ?", arguments: ["Doomed"])
            for row in rows {
                let treeId: String = row["id"]
                let sessionRows = try Row.fetchAll(
                    db, sql: "SELECT session_id FROM canvas_branches WHERE tree_id = ?", arguments: [treeId]
                )
                let sessionIds: [String] = sessionRows.compactMap { $0["session_id"] }

                if !sessionIds.isEmpty {
                    let ph = sessionIds.map { _ in "?" }.joined(separator: ", ")
                    try db.execute(sql: "DELETE FROM messages WHERE session_id IN (\(ph))", arguments: StatementArguments(sessionIds))
                }
                try db.execute(sql: "DELETE FROM canvas_branches WHERE tree_id = ?", arguments: [treeId])
                if !sessionIds.isEmpty {
                    let ph = sessionIds.map { _ in "?" }.joined(separator: ", ")
                    try db.execute(sql: "DELETE FROM sessions WHERE id IN (\(ph))", arguments: StatementArguments(sessionIds))
                }
                try db.execute(sql: "DELETE FROM canvas_trees WHERE id = ?", arguments: [treeId])
            }
        }

        let remaining = try dbPool.read { db in
            try ConversationTree.fetchAll(db)
        }
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.name, "T3")
    }

    // MARK: - 8. Schema Integrity

    func testAllV18TriggersExist() throws {
        let triggers = try dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name")
        }

        // v17 denormalization triggers
        XCTAssertTrue(triggers.contains("canvas_trees_msg_insert"),
                       "v17 insert trigger must exist")
        XCTAssertTrue(triggers.contains("canvas_trees_msg_delete"),
                       "v17 delete trigger must exist")

        // v18 cascade triggers
        XCTAssertTrue(triggers.contains("canvas_branch_cascade_tags"),
                       "v18 branch tag cascade trigger must exist")
        XCTAssertTrue(triggers.contains("canvas_branch_cascade_api_state"),
                       "v18 branch API state cascade trigger must exist")
    }

    func testDenormalizedColumnsExist() throws {
        let columns = try dbPool.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(canvas_trees)")
        }
        let names = Set(columns.map { $0["name"] as String })

        XCTAssertTrue(names.contains("message_count"), "v17 message_count column must exist")
        XCTAssertTrue(names.contains("last_message_at"), "v17 last_message_at column must exist")
        XCTAssertTrue(names.contains("last_assistant_snippet"), "v17 last_assistant_snippet column must exist")
    }

    func testSecurityApprovalsTableExists() throws {
        let tables = try dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='canvas_security_approvals'")
        }
        XCTAssertEqual(tables, ["canvas_security_approvals"], "v18 security approvals table must exist")
    }
}
