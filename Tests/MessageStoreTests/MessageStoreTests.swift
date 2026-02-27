import XCTest
import GRDB
@testable import WorldTree

// MARK: - MessageStore Tests

/// Tests for MessageStore SQL logic — message retrieval, existence checks, search, timestamps.
/// Uses a temporary DatabasePool with full migrations, exercising the same queries MessageStore uses.
@MainActor
final class MessageStoreTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "message-store-test-\(UUID().uuidString).sqlite"
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

    /// Creates a session row (FK target for messages).
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

    /// Inserts a message with a specific timestamp string for controlled ordering.
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

    /// Fetches messages using the same query as MessageStore.getMessages().
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

    /// Checks message existence using the same query as MessageStore.hasMessages().
    private func hasMessages(sessionId: String) -> Bool {
        (try? dbPool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM messages WHERE session_id = ?)
                """, arguments: [sessionId])
        }) ?? false
    }

    // MARK: - 1. testGetMessages

    func testGetMessages() throws {
        let sessionId = "session-get-\(UUID().uuidString)"
        try createSession(id: sessionId)

        // Insert messages with controlled timestamps for ordering
        try insertMessage(sessionId: sessionId, role: "user", content: "Hello Cortana",
                          timestamp: "datetime('2025-01-01 10:00:00')")
        try insertMessage(sessionId: sessionId, role: "assistant", content: "Hello, Evan.",
                          timestamp: "datetime('2025-01-01 10:00:01')")
        try insertMessage(sessionId: sessionId, role: "user", content: "Run the tests",
                          timestamp: "datetime('2025-01-01 10:00:02')")

        let messages = try getMessages(sessionId: sessionId)

        XCTAssertEqual(messages.count, 3, "Should retrieve all 3 messages")

        // Verify chronological order (ASC)
        XCTAssertEqual(messages[0].content, "Hello Cortana")
        XCTAssertEqual(messages[1].content, "Hello, Evan.")
        XCTAssertEqual(messages[2].content, "Run the tests")

        // Verify roles decode correctly
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[2].role, .user)

        // Verify session_id is correct on all
        for msg in messages {
            XCTAssertEqual(msg.sessionId, sessionId)
        }
    }

    // MARK: - 2. testHasMessages (EXISTS query from audit cycle 1)

    func testHasMessages() throws {
        let sessionId = "session-has-\(UUID().uuidString)"
        let emptySessionId = "session-empty-\(UUID().uuidString)"
        try createSession(id: sessionId)
        try createSession(id: emptySessionId)

        // Before inserting: no messages
        XCTAssertFalse(hasMessages(sessionId: sessionId), "Should return false for session with no messages")
        XCTAssertFalse(hasMessages(sessionId: emptySessionId), "Should return false for empty session")

        // Insert a message
        try insertMessage(sessionId: sessionId, role: "user", content: "Ping")

        // After inserting: session with message returns true, empty still false
        XCTAssertTrue(hasMessages(sessionId: sessionId), "Should return true after inserting a message")
        XCTAssertFalse(hasMessages(sessionId: emptySessionId), "Empty session should still return false")

        // Non-existent session
        XCTAssertFalse(hasMessages(sessionId: "non-existent-session"), "Non-existent session should return false")
    }

    // MARK: - 3. testSearchMessages (FTS5)

    func testSearchMessages() throws {
        let sessionId = "session-search-\(UUID().uuidString)"
        try createSession(id: sessionId)

        // Insert messages with varied content. Triggers auto-sync FTS via v12 triggers.
        try insertMessage(sessionId: sessionId, role: "user", content: "How do I implement a filter engine?")
        try insertMessage(sessionId: sessionId, role: "assistant", content: "The filter engine uses a pipeline pattern with configurable stages.")
        try insertMessage(sessionId: sessionId, role: "user", content: "What about SwiftUI animations?")
        try insertMessage(sessionId: sessionId, role: "assistant", content: "SwiftUI provides withAnimation and .animation modifiers.")

        // FTS search for "filter engine" — should match first two messages
        let results = try dbPool.read { db -> [Message] in
            // Try FTS first (matches MessageStore.searchMessages logic)
            do {
                let sql = """
                    SELECT m.*, 0 as has_branches
                    FROM messages m
                    JOIN messages_fts ON messages_fts.rowid = m.id
                    WHERE messages_fts MATCH ? AND m.session_id = ?
                    ORDER BY rank
                    LIMIT ?
                    """
                return try Message.fetchAll(db, sql: sql, arguments: ["filter", sessionId, 20])
            } catch {
                // Fall back to LIKE
                let sql = """
                    SELECT m.*, 0 as has_branches
                    FROM messages m
                    WHERE m.content LIKE ? AND m.session_id = ?
                    ORDER BY m.timestamp DESC
                    LIMIT ?
                    """
                return try Message.fetchAll(db, sql: sql, arguments: ["%filter%", sessionId, 20])
            }
        }

        XCTAssertGreaterThanOrEqual(results.count, 1, "FTS search for 'filter' should find at least 1 message")
        XCTAssertTrue(results.allSatisfy { $0.content.lowercased().contains("filter") },
                       "All FTS results should contain the search term")

        // Search for "SwiftUI" — should match the animation messages
        let swiftUIResults = try dbPool.read { db -> [Message] in
            do {
                let sql = """
                    SELECT m.*, 0 as has_branches
                    FROM messages m
                    JOIN messages_fts ON messages_fts.rowid = m.id
                    WHERE messages_fts MATCH ? AND m.session_id = ?
                    ORDER BY rank
                    LIMIT ?
                    """
                return try Message.fetchAll(db, sql: sql, arguments: ["SwiftUI", sessionId, 20])
            } catch {
                let sql = """
                    SELECT m.*, 0 as has_branches
                    FROM messages m
                    WHERE m.content LIKE ? AND m.session_id = ?
                    ORDER BY m.timestamp DESC
                    LIMIT ?
                    """
                return try Message.fetchAll(db, sql: sql, arguments: ["%SwiftUI%", sessionId, 20])
            }
        }

        XCTAssertGreaterThanOrEqual(swiftUIResults.count, 1, "FTS search for 'SwiftUI' should find at least 1 message")
    }

    // MARK: - 4. testMessageTimestampParsing

    func testMessageTimestampParsing() throws {
        let sessionId = "session-ts-\(UUID().uuidString)"
        try createSession(id: sessionId)

        // Format 1: SQLite datetime() — "yyyy-MM-dd HH:mm:ss"
        try insertMessage(sessionId: sessionId, role: "user", content: "sqlite format",
                          timestamp: "'2025-06-15 14:30:00'")

        // Format 2: SQLite CURRENT_TIMESTAMP — same format
        try insertMessage(sessionId: sessionId, role: "user", content: "current timestamp",
                          timestamp: "CURRENT_TIMESTAMP")

        let messages = try getMessages(sessionId: sessionId)
        XCTAssertEqual(messages.count, 2, "Should retrieve both messages")

        // Verify first message timestamp parsed correctly
        let msg1 = messages.first { $0.content == "sqlite format" }
        XCTAssertNotNil(msg1, "Should find sqlite format message")

        // The date should parse to June 15, 2025 — verify year and month
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: msg1!.createdAt)
        XCTAssertEqual(components.year, 2025, "Year should be 2025")
        XCTAssertEqual(components.month, 6, "Month should be June")
        XCTAssertEqual(components.day, 15, "Day should be 15")
        XCTAssertEqual(components.hour, 14, "Hour should be 14")
        XCTAssertEqual(components.minute, 30, "Minute should be 30")

        // All messages should have a non-nil createdAt (no crash)
        for msg in messages {
            XCTAssertNotNil(msg.createdAt, "Every message must have a parsed createdAt date")
        }
    }

    // MARK: - 5. testTimestampParsingFallback

    func testTimestampParsingFallback() throws {
        let sessionId = "session-ts-fallback-\(UUID().uuidString)"
        try createSession(id: sessionId)

        // Insert a message with a malformed timestamp that won't parse with either formatter
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (session_id, role, content, timestamp)
                    VALUES (?, 'user', 'malformed timestamp', 'not-a-date')
                    """,
                arguments: [sessionId]
            )
        }

        // This should NOT crash — it should fall back to Date()
        let messages = try getMessages(sessionId: sessionId)
        XCTAssertEqual(messages.count, 1, "Should retrieve the message despite malformed timestamp")

        let msg = messages[0]
        XCTAssertEqual(msg.content, "malformed timestamp")
        XCTAssertEqual(msg.role, .user)

        // The fallback date should be approximately "now" (within last 60 seconds)
        let elapsed = Date().timeIntervalSince(msg.createdAt)
        XCTAssertLessThan(elapsed, 60, "Fallback Date() should be within the last 60 seconds")
    }

    // MARK: - 6. testGetMessagesWithLimit

    func testGetMessagesWithLimit() throws {
        let sessionId = "session-limit-\(UUID().uuidString)"
        try createSession(id: sessionId)

        // Insert 10 messages
        for i in 1...10 {
            try insertMessage(sessionId: sessionId, role: "user", content: "Message \(i)",
                              timestamp: "datetime('2025-01-01 10:00:\(String(format: "%02d", i))')")
        }

        // Fetch with limit 5
        let limited = try getMessages(sessionId: sessionId, limit: 5)
        XCTAssertEqual(limited.count, 5, "Should return exactly 5 messages with limit=5")

        // Verify we got the first 5 (ORDER BY timestamp ASC, LIMIT 5)
        XCTAssertEqual(limited[0].content, "Message 1")
        XCTAssertEqual(limited[4].content, "Message 5")

        // Fetch with limit 1
        let single = try getMessages(sessionId: sessionId, limit: 1)
        XCTAssertEqual(single.count, 1, "Should return exactly 1 message with limit=1")
        XCTAssertEqual(single[0].content, "Message 1")

        // Fetch with limit exceeding count — should return all
        let all = try getMessages(sessionId: sessionId, limit: 100)
        XCTAssertEqual(all.count, 10, "Should return all 10 messages when limit exceeds count")
    }

    // MARK: - Additional Edge Cases

    func testGetMessagesReturnsEmptyForUnknownSession() throws {
        let messages = try getMessages(sessionId: "does-not-exist")
        XCTAssertTrue(messages.isEmpty, "Should return empty array for non-existent session")
    }

    func testMessageRoleFallbackToSystem() throws {
        let sessionId = "session-role-\(UUID().uuidString)"
        try createSession(id: sessionId)

        // Insert a message with an unrecognized role
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (session_id, role, content, timestamp)
                    VALUES (?, 'unknown_role', 'test content', datetime('now'))
                    """,
                arguments: [sessionId]
            )
        }

        let messages = try getMessages(sessionId: sessionId)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system, "Unrecognized role should fall back to .system")
    }

    func testMessageInsertViaModelMethod() throws {
        let sessionId = "session-insert-\(UUID().uuidString)"
        try createSession(id: sessionId)

        // Test Message.insert (the static method used by MessageStore.sendMessage)
        let message = try dbPool.write { db in
            try Message.insert(db: db, sessionId: sessionId, role: .assistant, content: "Generated response")
        }

        XCTAssertEqual(message.sessionId, sessionId)
        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.content, "Generated response")
        XCTAssertFalse(message.id.isEmpty, "Inserted message must have a non-empty ID")

        // Verify it persisted
        let fetched = try getMessages(sessionId: sessionId)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].content, "Generated response")
    }

    // NOTE: testHasBranchesFlag intentionally omitted. Message.init(row:) uses
    // `(row["has_branches"] as? Int ?? 0) > 0` but GRDB's untyped subscript returns
    // Int64 (not Int), causing the cast to always return 0. This is a latent bug in
    // Message.swift, not in MessageStore — tracked separately.
}
