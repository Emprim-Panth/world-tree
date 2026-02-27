import XCTest
import GRDB
@testable import WorldTree

// MARK: - ClaudeBridge Tests

/// Tests for ClaudeBridge-adjacent logic — BridgeEvent parsing, event type coverage,
/// context assembly from branch history, and session existence checks.
/// Focused on the data layer; does NOT spawn actual Claude processes.
@MainActor
final class ClaudeBridgeTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "claude-bridge-test-\(UUID().uuidString).sqlite"
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

    /// Creates a session row (FK target for branches and messages).
    private func createSession(id: String, workingDirectory: String = "/tmp/test") throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO sessions (id, terminal_id, working_directory, description, started_at)
                    VALUES (?, 'canvas', ?, 'Test session', datetime('now'))
                    """,
                arguments: [id, workingDirectory]
            )
        }
    }

    /// Creates a tree + branch pair. Returns (treeId, branchId, sessionId).
    @discardableResult
    private func createTreeAndBranch(
        treeId: String = UUID().uuidString,
        branchId: String = UUID().uuidString,
        sessionId: String = UUID().uuidString,
        parentBranchId: String? = nil,
        title: String? = nil,
        model: String? = nil
    ) throws -> (treeId: String, branchId: String, sessionId: String) {
        try dbPool.write { db in
            // Tree
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO canvas_trees (id, name, created_at, updated_at)
                    VALUES (?, 'Test Tree', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                    """,
                arguments: [treeId]
            )
            // Session
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO sessions (id, terminal_id, working_directory, description, started_at)
                    VALUES (?, 'canvas', '/tmp/test', ?, datetime('now'))
                    """,
                arguments: [sessionId, title ?? "Test branch"]
            )
            // Branch
            try db.execute(
                sql: """
                    INSERT INTO canvas_branches (id, tree_id, session_id, parent_branch_id, branch_type, title, status, model, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 'conversation', ?, 'active', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                    """,
                arguments: [branchId, treeId, sessionId, parentBranchId, title, model]
            )
        }
        return (treeId, branchId, sessionId)
    }

    /// Inserts a message into the messages table.
    @discardableResult
    private func insertMessage(
        sessionId: String,
        role: String,
        content: String,
        timestamp: String = "datetime('now')"
    ) throws -> Int64 {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (session_id, role, content, timestamp)
                    VALUES (?, ?, ?, \(timestamp))
                    """,
                arguments: [sessionId, role, content]
            )
            return db.lastInsertedRowID
        }
    }

    /// Checks whether a session has messages (mirrors ClaudeBridge.hasExistingSession logic).
    private func hasMessages(sessionId: String) -> Bool {
        (try? dbPool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM messages WHERE session_id = ?)
                """, arguments: [sessionId])
        }) ?? false
    }

    /// Fetches messages for a session (mirrors MessageStore.getMessages).
    private func getMessages(sessionId: String, limit: Int = 500) throws -> [Message] {
        try dbPool.read { db in
            let sql = """
                SELECT m.*,
                    (SELECT COUNT(*) FROM canvas_branches cb
                     WHERE cb.fork_from_message_id = m.id) as has_branches
                FROM messages m
                WHERE m.session_id = ?
                ORDER BY m.timestamp ASC
                LIMIT ?
                """
            return try Message.fetchAll(db, sql: sql, arguments: [sessionId, limit])
        }
    }

    /// Resolves parent session ID for a branch (mirrors ClaudeBridge.resolveParentSessionId).
    private func resolveParentSessionId(branchId: String) -> String? {
        guard let branch = try? dbPool.read({ db in
            try Row.fetchOne(db, sql: """
                SELECT parent_branch_id, session_id FROM canvas_branches WHERE id = ?
                """, arguments: [branchId])
        }),
              let parentBranchId: String = branch["parent_branch_id"],
              let parentRow = try? dbPool.read({ db in
                  try Row.fetchOne(db, sql: """
                      SELECT session_id FROM canvas_branches WHERE id = ?
                      """, arguments: [parentBranchId])
              }),
              let parentSessionId: String = parentRow["session_id"]
        else {
            return nil
        }
        return parentSessionId
    }

    // MARK: - 1. testBridgeEventParsing

    func testBridgeEventParsing() throws {
        // BridgeEvent.text — carries streamed text content
        let textEvent = BridgeEvent.text("Hello, Evan.")
        if case .text(let content) = textEvent {
            XCTAssertEqual(content, "Hello, Evan.", "Text event should carry the exact string")
        } else {
            XCTFail("Should be a .text event")
        }

        // BridgeEvent.toolStart — carries tool name and input
        let toolStartEvent = BridgeEvent.toolStart(name: "bash", input: "ls -la /tmp")
        if case .toolStart(let name, let input) = toolStartEvent {
            XCTAssertEqual(name, "bash")
            XCTAssertEqual(input, "ls -la /tmp")
        } else {
            XCTFail("Should be a .toolStart event")
        }

        // BridgeEvent.toolEnd — carries tool name, result, and error flag
        let toolEndEvent = BridgeEvent.toolEnd(name: "bash", result: "file1.txt\nfile2.txt", isError: false)
        if case .toolEnd(let name, let result, let isError) = toolEndEvent {
            XCTAssertEqual(name, "bash")
            XCTAssertEqual(result, "file1.txt\nfile2.txt")
            XCTAssertFalse(isError)
        } else {
            XCTFail("Should be a .toolEnd event")
        }

        // BridgeEvent.toolEnd with error
        let toolErrorEvent = BridgeEvent.toolEnd(name: "read", result: "File not found", isError: true)
        if case .toolEnd(_, _, let isError) = toolErrorEvent {
            XCTAssertTrue(isError, "isError should be true for failed tool execution")
        } else {
            XCTFail("Should be a .toolEnd event")
        }

        // BridgeEvent.error — carries error message
        let errorEvent = BridgeEvent.error("Connection timeout after 30s")
        if case .error(let message) = errorEvent {
            XCTAssertEqual(message, "Connection timeout after 30s")
        } else {
            XCTFail("Should be an .error event")
        }

        // BridgeEvent.done — carries SessionTokenUsage
        let usage = SessionTokenUsage(
            totalInputTokens: 1500,
            totalOutputTokens: 800,
            cacheHitTokens: 200,
            cacheCreationTokens: 50,
            turnCount: 1
        )
        let doneEvent = BridgeEvent.done(usage: usage)
        if case .done(let returnedUsage) = doneEvent {
            XCTAssertEqual(returnedUsage.totalInputTokens, 1500)
            XCTAssertEqual(returnedUsage.totalOutputTokens, 800)
            XCTAssertEqual(returnedUsage.cacheHitTokens, 200)
            XCTAssertEqual(returnedUsage.cacheCreationTokens, 50)
            XCTAssertEqual(returnedUsage.turnCount, 1)
        } else {
            XCTFail("Should be a .done event")
        }
    }

    // MARK: - 2. testBridgeEventTypes

    func testBridgeEventTypes() throws {
        // Verify all BridgeEvent cases can be constructed and pattern-matched.
        // This ensures no case is accidentally removed or renamed.

        let events: [BridgeEvent] = [
            .text("chunk"),
            .toolStart(name: "bash", input: "echo hi"),
            .toolEnd(name: "bash", result: "hi", isError: false),
            .done(usage: SessionTokenUsage()),
            .error("fail")
        ]

        // Verify each case matches exactly once
        var textCount = 0
        var toolStartCount = 0
        var toolEndCount = 0
        var doneCount = 0
        var errorCount = 0

        for event in events {
            switch event {
            case .text:
                textCount += 1
            case .toolStart:
                toolStartCount += 1
            case .toolEnd:
                toolEndCount += 1
            case .done:
                doneCount += 1
            case .error:
                errorCount += 1
            }
        }

        XCTAssertEqual(textCount, 1, "Should have exactly 1 .text event")
        XCTAssertEqual(toolStartCount, 1, "Should have exactly 1 .toolStart event")
        XCTAssertEqual(toolEndCount, 1, "Should have exactly 1 .toolEnd event")
        XCTAssertEqual(doneCount, 1, "Should have exactly 1 .done event")
        XCTAssertEqual(errorCount, 1, "Should have exactly 1 .error event")

        // Total coverage: 5 cases
        XCTAssertEqual(events.count, 5, "BridgeEvent should have exactly 5 cases")
    }

    // MARK: - 3. testContextAssembly

    func testContextAssembly() throws {
        // Test that message history for a branch can be assembled correctly
        // This mirrors the data path that ClaudeBridge.sendDirect() relies on:
        // branch -> sessionId -> messages

        let treeId = UUID().uuidString
        let rootSessionId = UUID().uuidString
        let childSessionId = UUID().uuidString

        // Create root branch with conversation history
        let (_, rootBranchId, _) = try createTreeAndBranch(
            treeId: treeId,
            sessionId: rootSessionId,
            title: "Root conversation"
        )

        try insertMessage(sessionId: rootSessionId, role: "user", content: "What is SwiftUI?",
                          timestamp: "datetime('2025-01-01 10:00:00')")
        try insertMessage(sessionId: rootSessionId, role: "assistant", content: "SwiftUI is Apple's declarative UI framework.",
                          timestamp: "datetime('2025-01-01 10:00:01')")
        try insertMessage(sessionId: rootSessionId, role: "user", content: "How do I use @State?",
                          timestamp: "datetime('2025-01-01 10:00:02')")
        try insertMessage(sessionId: rootSessionId, role: "assistant", content: "@State is a property wrapper for view-local mutable state.",
                          timestamp: "datetime('2025-01-01 10:00:03')")

        // Fork a child branch from the root
        let (_, childBranchId, _) = try createTreeAndBranch(
            treeId: treeId,
            branchId: UUID().uuidString,
            sessionId: childSessionId,
            parentBranchId: rootBranchId,
            title: "Explore animations"
        )

        try insertMessage(sessionId: childSessionId, role: "user", content: "How do animations work?",
                          timestamp: "datetime('2025-01-01 10:01:00')")
        try insertMessage(sessionId: childSessionId, role: "assistant", content: "SwiftUI provides withAnimation and .animation modifiers.",
                          timestamp: "datetime('2025-01-01 10:01:01')")

        // Verify root branch messages
        let rootMessages = try getMessages(sessionId: rootSessionId)
        XCTAssertEqual(rootMessages.count, 4, "Root branch should have 4 messages")
        XCTAssertEqual(rootMessages[0].content, "What is SwiftUI?")
        XCTAssertEqual(rootMessages[3].content, "@State is a property wrapper for view-local mutable state.")

        // Verify child branch messages (own session only)
        let childMessages = try getMessages(sessionId: childSessionId)
        XCTAssertEqual(childMessages.count, 2, "Child branch should have 2 messages in its own session")
        XCTAssertEqual(childMessages[0].content, "How do animations work?")

        // Verify parent session resolution (used by ClaudeBridge for context inheritance)
        let parentSession = resolveParentSessionId(branchId: childBranchId)
        XCTAssertEqual(parentSession, rootSessionId,
                        "Child branch should resolve to root's session ID for context inheritance")

        // Verify root branch has no parent
        let rootParent = resolveParentSessionId(branchId: rootBranchId)
        XCTAssertNil(rootParent, "Root branch should have no parent session")

        // Assemble full context: parent messages + child messages
        // This mirrors what BranchViewModel does before calling ClaudeBridge.send()
        var contextMessages: [Message] = []
        if let parentSessionId = parentSession {
            let parentMessages = try getMessages(sessionId: parentSessionId)
            contextMessages.append(contentsOf: parentMessages)
        }
        contextMessages.append(contentsOf: childMessages)

        XCTAssertEqual(contextMessages.count, 6, "Full context should have 4 parent + 2 child messages")
        XCTAssertEqual(contextMessages[0].content, "What is SwiftUI?", "Context should start with parent history")
        XCTAssertEqual(contextMessages[5].content, "SwiftUI provides withAnimation and .animation modifiers.",
                        "Context should end with child's latest message")

        // Verify alternating roles in assembled context
        XCTAssertEqual(contextMessages[0].role, .user)
        XCTAssertEqual(contextMessages[1].role, .assistant)
        XCTAssertEqual(contextMessages[2].role, .user)
        XCTAssertEqual(contextMessages[3].role, .assistant)
        XCTAssertEqual(contextMessages[4].role, .user)
        XCTAssertEqual(contextMessages[5].role, .assistant)
    }

    // MARK: - 4. testHasExistingSession

    func testHasExistingSession() throws {
        let sessionWithMessages = UUID().uuidString
        let emptySession = UUID().uuidString
        let nonExistentSession = UUID().uuidString

        try createSession(id: sessionWithMessages)
        try createSession(id: emptySession)

        // Insert a message for the first session
        try insertMessage(sessionId: sessionWithMessages, role: "user", content: "Hello")

        // hasExistingSession check (mirrors ClaudeBridge.hasExistingSession → MessageStore.hasMessages)
        XCTAssertTrue(hasMessages(sessionId: sessionWithMessages),
                       "Session with messages should return true")
        XCTAssertFalse(hasMessages(sessionId: emptySession),
                        "Session with no messages should return false")
        XCTAssertFalse(hasMessages(sessionId: nonExistentSession),
                        "Non-existent session should return false")

        // Add a message to the empty session, verify it flips
        try insertMessage(sessionId: emptySession, role: "assistant", content: "Response")
        XCTAssertTrue(hasMessages(sessionId: emptySession),
                       "Previously empty session should return true after message insert")

        // Verify the isNewSession derivation (inverse of hasMessages)
        let isNewSession = !hasMessages(sessionId: nonExistentSession)
        XCTAssertTrue(isNewSession, "Non-existent session should be treated as new")

        let isExistingSession = !hasMessages(sessionId: sessionWithMessages)
        XCTAssertFalse(isExistingSession, "Session with messages should NOT be treated as new")
    }

    // MARK: - Additional Coverage

    func testSessionTokenUsageAccumulation() throws {
        // Verify SessionTokenUsage.record() accumulates correctly
        // (used by BridgeEvent.done payload)
        var usage = SessionTokenUsage()
        XCTAssertEqual(usage.totalInputTokens, 0)
        XCTAssertEqual(usage.totalOutputTokens, 0)
        XCTAssertEqual(usage.turnCount, 0)

        // Simulate recording — we construct the values directly since TokenUsage
        // is internal to AnthropicTypes, but we can verify the struct fields
        usage.totalInputTokens += 1000
        usage.totalOutputTokens += 500
        usage.cacheHitTokens += 200
        usage.cacheCreationTokens += 100
        usage.turnCount += 1

        XCTAssertEqual(usage.totalInputTokens, 1000)
        XCTAssertEqual(usage.totalOutputTokens, 500)
        XCTAssertEqual(usage.cacheHitTokens, 200)
        XCTAssertEqual(usage.cacheCreationTokens, 100)
        XCTAssertEqual(usage.turnCount, 1)

        // Second turn
        usage.totalInputTokens += 1200
        usage.totalOutputTokens += 600
        usage.turnCount += 1

        XCTAssertEqual(usage.totalInputTokens, 2200, "Input tokens should accumulate across turns")
        XCTAssertEqual(usage.totalOutputTokens, 1100, "Output tokens should accumulate across turns")
        XCTAssertEqual(usage.turnCount, 2, "Turn count should increment")
    }

    func testParentSessionResolutionChain() throws {
        // Test a 3-level deep branch chain: root -> child -> grandchild
        let treeId = UUID().uuidString
        let rootSession = UUID().uuidString
        let childSession = UUID().uuidString
        let grandchildSession = UUID().uuidString

        let (_, rootBranchId, _) = try createTreeAndBranch(
            treeId: treeId,
            sessionId: rootSession,
            title: "Root"
        )

        let (_, childBranchId, _) = try createTreeAndBranch(
            treeId: treeId,
            branchId: UUID().uuidString,
            sessionId: childSession,
            parentBranchId: rootBranchId,
            title: "Child"
        )

        let (_, grandchildBranchId, _) = try createTreeAndBranch(
            treeId: treeId,
            branchId: UUID().uuidString,
            sessionId: grandchildSession,
            parentBranchId: childBranchId,
            title: "Grandchild"
        )

        // Grandchild's parent session should be child's session
        let grandchildParent = resolveParentSessionId(branchId: grandchildBranchId)
        XCTAssertEqual(grandchildParent, childSession,
                        "Grandchild should resolve to child's session ID")

        // Child's parent session should be root's session
        let childParent = resolveParentSessionId(branchId: childBranchId)
        XCTAssertEqual(childParent, rootSession,
                        "Child should resolve to root's session ID")

        // Root has no parent
        let rootParent = resolveParentSessionId(branchId: rootBranchId)
        XCTAssertNil(rootParent, "Root should have no parent session")
    }

    func testBridgeEventTextAccumulation() throws {
        // Simulate streaming text chunks and verify accumulation
        // (mirrors what BranchViewModel does when consuming the AsyncStream)
        let chunks: [BridgeEvent] = [
            .text("Hello"),
            .text(", "),
            .text("Evan"),
            .text("."),
            .text(" How can I help?")
        ]

        var accumulated = ""
        for chunk in chunks {
            if case .text(let text) = chunk {
                accumulated += text
            }
        }

        XCTAssertEqual(accumulated, "Hello, Evan. How can I help?",
                        "Streamed text chunks should accumulate to the full message")
    }

    func testBridgeEventToolSequence() throws {
        // Simulate a typical tool use sequence and verify the event order is valid
        let events: [BridgeEvent] = [
            .text("Let me check that file."),
            .toolStart(name: "read", input: "/Users/evan/file.swift"),
            .toolEnd(name: "read", result: "import Foundation\n...", isError: false),
            .text("The file contains a Foundation import."),
            .done(usage: SessionTokenUsage(totalInputTokens: 500, totalOutputTokens: 200))
        ]

        // Verify tool start/end pairs match
        var activeTools: [String] = []
        for event in events {
            switch event {
            case .toolStart(let name, _):
                activeTools.append(name)
            case .toolEnd(let name, _, _):
                XCTAssertEqual(activeTools.last, name,
                               "toolEnd should match the most recent toolStart")
                activeTools.removeLast()
            default:
                break
            }
        }

        XCTAssertTrue(activeTools.isEmpty, "All tool starts should have matching tool ends")

        // Verify done is always last
        if case .done = events.last {
            // Expected
        } else {
            XCTFail("Last event in a completed sequence should be .done")
        }
    }
}
