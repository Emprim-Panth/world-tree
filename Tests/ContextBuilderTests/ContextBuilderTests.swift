import XCTest
import GRDB
@testable import WorldTree

// MARK: - ContextBuilder Unit Tests

/// Tests for ContextBuilder — fork context assembly, message truncation,
/// section ordering, and edge cases (nil session, empty messages).
///
/// ContextBuilder.buildForkContext depends on MessageStore.shared, which depends on
/// DatabaseManager.shared. We inject a test pool via setDatabasePoolForTesting().
@MainActor
final class ContextBuilderTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "contextbuilder-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)
        try MigrationManager.migrate(dbPool)
        DatabaseManager.shared.setDatabasePoolForTesting(dbPool)
    }

    override func tearDown() async throws {
        DatabaseManager.shared.setDatabasePoolForTesting(nil)
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

    private func createTree(id: String = "tree-1") throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO canvas_trees (id, name) VALUES (?, 'Test Tree')
                """, arguments: [id])
        }
    }

    private func createBranch(
        id: String,
        treeId: String = "tree-1",
        sessionId: String?,
        branchType: String = "conversation",
        title: String? = nil
    ) throws -> Branch {
        try dbPool.write { db in
            if let sessionId {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO sessions (id, terminal_id, working_directory, description, started_at)
                    VALUES (?, 'canvas', '/tmp/test', ?, datetime('now'))
                    """, arguments: [sessionId, title ?? "Test session"])
            }
            try db.execute(sql: """
                INSERT INTO canvas_branches (id, tree_id, session_id, branch_type, title, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'active', datetime('now'), datetime('now'))
                """, arguments: [id, treeId, sessionId, branchType, title])
        }
        return try dbPool.read { db in
            try Branch.fetchOne(db, sql: "SELECT * FROM canvas_branches WHERE id = ?", arguments: [id])!
        }
    }

    private func createSession(id: String) throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO sessions (id, terminal_id, working_directory, description, started_at)
                VALUES (?, 'canvas', '/tmp/test', 'Test session', datetime('now'))
                """, arguments: [id])
        }
    }

    private func insertMessage(sessionId: String, role: String, content: String, id: Int? = nil) throws -> Int64 {
        try dbPool.write { db in
            if let id = id {
                try db.execute(sql: """
                    INSERT INTO messages (id, session_id, role, content, timestamp)
                    VALUES (?, ?, ?, ?, datetime('now'))
                    """, arguments: [id, sessionId, role, content])
                return Int64(id)
            } else {
                try db.execute(sql: """
                    INSERT INTO messages (session_id, role, content, timestamp)
                    VALUES (?, ?, ?, datetime('now'))
                    """, arguments: [sessionId, role, content])
                return db.lastInsertedRowID
            }
        }
    }

    // MARK: - 1. Nil Session Returns Nil

    func testBuildForkContextReturnsNilForNilSession() throws {
        try createTree()
        let branch = try createBranch(id: "b1", sessionId: nil)

        let context = try ContextBuilder.buildForkContext(
            parentBranch: branch,
            forkMessageId: "msg-1"
        )

        XCTAssertNil(context, "buildForkContext should return nil when parentBranch has nil sessionId")
    }

    // MARK: - 2. Context Contains Branch Metadata Section

    func testForkContextContainsBranchMetadata() throws {
        try createTree()
        let sessionId = "session-ctx-1"
        try createSession(id: sessionId)
        let branch = try createBranch(id: "b1", sessionId: sessionId, branchType: "exploration", title: "Test Branch")

        let msgId = try insertMessage(sessionId: sessionId, role: "user", content: "Hello")

        let context = try ContextBuilder.buildForkContext(
            parentBranch: branch,
            forkMessageId: String(msgId)
        )

        XCTAssertNotNil(context)
        XCTAssertTrue(context!.contains("Test Branch"), "Context should include the branch title")
        XCTAssertTrue(context!.contains("exploration"), "Context should include the branch type")
    }

    // MARK: - 3. Section Ordering

    func testForkContextSectionOrdering() throws {
        try createTree()
        let sessionId = "session-order-1"
        try createSession(id: sessionId)
        let branch = try createBranch(id: "b1", sessionId: sessionId)

        let msgId = try insertMessage(sessionId: sessionId, role: "user", content: "Test message")

        let context = try ContextBuilder.buildForkContext(
            parentBranch: branch,
            forkMessageId: String(msgId)
        )

        XCTAssertNotNil(context)
        let text = context!

        // Metadata section should come before messages
        let metadataRange = text.range(of: "[Context from branch")
        let messagesRange = text.range(of: "[Recent conversation")
        let forkRange = text.range(of: "[You are branching from this point")

        XCTAssertNotNil(metadataRange, "Should contain metadata section")
        XCTAssertNotNil(forkRange, "Should contain fork indicator section")

        if let meta = metadataRange, let fork = forkRange {
            XCTAssertTrue(meta.lowerBound < fork.lowerBound,
                          "Metadata should appear before fork indicator")
        }

        // If messages section exists, it should be between metadata and fork indicator
        if let msgs = messagesRange, let meta = metadataRange, let fork = forkRange {
            XCTAssertTrue(meta.lowerBound < msgs.lowerBound,
                          "Metadata should appear before messages")
            XCTAssertTrue(msgs.lowerBound < fork.lowerBound,
                          "Messages should appear before fork indicator")
        }
    }

    // MARK: - 4. Fork Indicator Always Present

    func testForkContextAlwaysEndWithForkIndicator() throws {
        try createTree()
        let sessionId = "session-fork-ind"
        try createSession(id: sessionId)
        let branch = try createBranch(id: "b1", sessionId: sessionId)

        let msgId = try insertMessage(sessionId: sessionId, role: "user", content: "Test")

        let context = try ContextBuilder.buildForkContext(
            parentBranch: branch,
            forkMessageId: String(msgId)
        )

        XCTAssertNotNil(context)
        XCTAssertTrue(context!.contains("You are branching from this point"),
                      "Fork indicator should always be present")
    }

    // MARK: - 5. Truncation at 500 Characters

    func testMessageTruncationAt500Chars() throws {
        try createTree()
        let sessionId = "session-trunc"
        try createSession(id: sessionId)
        let branch = try createBranch(id: "b1", sessionId: sessionId)

        // Insert a message longer than 500 chars
        let longContent = String(repeating: "A", count: 800)
        let msgId = try insertMessage(sessionId: sessionId, role: "user", content: longContent)

        let context = try ContextBuilder.buildForkContext(
            parentBranch: branch,
            forkMessageId: String(msgId)
        )

        XCTAssertNotNil(context)

        // The truncated message should have at most 503 chars (500 + "...")
        // We check that the full 800-char string is NOT present
        XCTAssertFalse(context!.contains(longContent),
                       "Full 800-char content should not appear — it should be truncated")
        XCTAssertTrue(context!.contains("..."),
                      "Truncated messages should end with ellipsis")
    }

    // MARK: - 6. Empty Messages Still Produces Context

    func testForkContextWithNoMessages() throws {
        try createTree()
        let sessionId = "session-empty-msgs"
        try createSession(id: sessionId)
        let branch = try createBranch(id: "b1", sessionId: sessionId)

        // No messages inserted — use a nonexistent message ID
        let context = try ContextBuilder.buildForkContext(
            parentBranch: branch,
            forkMessageId: "nonexistent-msg"
        )

        XCTAssertNotNil(context, "Context should still be non-nil even with no messages")
        // Should have metadata and fork indicator but no messages section
        XCTAssertTrue(context!.contains("[Context from branch"))
        XCTAssertTrue(context!.contains("You are branching from this point"))
        XCTAssertFalse(context!.contains("[Recent conversation"),
                       "Should not have messages section when there are no messages")
    }

    // MARK: - 7. Implementation Context

    func testBuildImplementationContextAddsInstruction() throws {
        try createTree()
        let sessionId = "session-impl"
        try createSession(id: sessionId)
        let branch = try createBranch(id: "b1", sessionId: sessionId)

        let msgId = try insertMessage(sessionId: sessionId, role: "user", content: "Plan the architecture")

        let context = try ContextBuilder.buildImplementationContext(
            parentBranch: branch,
            forkMessageId: String(msgId),
            instruction: "Build the REST API layer"
        )

        XCTAssertNotNil(context)
        XCTAssertTrue(context!.contains("Build the REST API layer"),
                      "Implementation context should include the instruction")
        XCTAssertTrue(context!.contains("implementation branch"),
                      "Should contain implementation branch marker")
    }

    func testBuildImplementationContextReturnsNilForNilSession() throws {
        try createTree()
        let branch = try createBranch(id: "b1", sessionId: nil)

        let context = try ContextBuilder.buildImplementationContext(
            parentBranch: branch,
            forkMessageId: "msg-1",
            instruction: "Do something"
        )

        XCTAssertNil(context, "Implementation context should return nil when session is nil")
    }

    // MARK: - 8. Child Digest

    func testBuildChildDigestWithSummary() throws {
        try createTree()
        var branch = try createBranch(id: "b1", sessionId: "s1", branchType: "implementation", title: "API Work")
        // Manually set summary for testing since it's a var
        branch.summary = "Built the REST API with 5 endpoints"

        let digest = ContextBuilder.buildChildDigest(childBranch: branch)

        XCTAssertNotNil(digest)
        XCTAssertTrue(digest!.contains("implementation"), "Digest should include branch type")
        XCTAssertTrue(digest!.contains("API Work"), "Digest should include branch title")
        XCTAssertTrue(digest!.contains("Built the REST API"), "Digest should include summary")
    }

    func testBuildChildDigestReturnsNilWithoutSummary() throws {
        try createTree()
        let branch = try createBranch(id: "b1", sessionId: "s1")

        let digest = ContextBuilder.buildChildDigest(childBranch: branch)
        XCTAssertNil(digest, "Child digest should be nil when branch has no summary")
    }
}
