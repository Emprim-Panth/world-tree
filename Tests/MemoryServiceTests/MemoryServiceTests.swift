import XCTest
import GRDB
@testable import WorldTree

// MARK: - MemoryService Unit Tests

/// Tests for the MemoryService cross-session memory recall system.
///
/// MemoryService searches conversation_archive, conversation_archive_fts,
/// knowledge, and knowledge_fts tables to build contextual memory blocks.
/// Tests exercise the FTS query builder, recent activity summaries, FTS search,
/// char budget enforcement, and graceful degradation with missing tables.
///
/// Each test gets a fresh temporary database with the required tables created
/// via MigrationManager (which includes conversation_archive + FTS in v15/v16).
/// DatabaseManager.shared is pointed at the test database for integration tests.
@MainActor
final class MemoryServiceTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!
    private var sut: MemoryService { .shared }

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "memoryservice-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)

        // Run all migrations — this creates conversation_archive, conversation_archive_fts,
        // and the FTS sync triggers (v15 + v16)
        try MigrationManager.migrate(dbPool)

        // Create the knowledge + knowledge_fts tables manually since they're
        // owned by cortana-core (not created by MigrationManager)
        try await dbPool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS knowledge (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL DEFAULT 'pattern',
                    title TEXT NOT NULL,
                    content TEXT NOT NULL,
                    source TEXT,
                    confidence REAL DEFAULT 1.0,
                    is_active INTEGER DEFAULT 1,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)

            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(
                    title, content,
                    content='knowledge',
                    content_rowid='rowid'
                )
                """)

            // Sync triggers for knowledge_fts
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS knowledge_fts_ai AFTER INSERT ON knowledge BEGIN
                    INSERT INTO knowledge_fts(rowid, title, content)
                    VALUES (new.rowid, new.title, new.content);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS knowledge_fts_ad AFTER DELETE ON knowledge BEGIN
                    INSERT INTO knowledge_fts(knowledge_fts, rowid, title, content)
                    VALUES('delete', old.rowid, old.title, old.content);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS knowledge_fts_au AFTER UPDATE ON knowledge BEGIN
                    INSERT INTO knowledge_fts(knowledge_fts, rowid, title, content)
                    VALUES('delete', old.rowid, old.title, old.content);
                    INSERT INTO knowledge_fts(rowid, title, content)
                    VALUES (new.rowid, new.title, new.content);
                END
                """)
        }

        // Point DatabaseManager.shared at the test database so MemoryService reads from it
        DatabaseManager.shared.setDatabasePoolForTesting(dbPool)

        // Clear the table-exists cache so each test starts fresh
        MemoryService.resetTableExistsCache()
    }

    override func tearDown() async throws {
        // Disconnect the test database from DatabaseManager
        DatabaseManager.shared.setDatabasePoolForTesting(nil)
        dbPool = nil
        if let path = dbPath {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
        dbPath = nil
        MemoryService.resetTableExistsCache()
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Inserts a conversation_archive row. The FTS sync trigger auto-updates conversation_archive_fts.
    private func insertArchiveEntry(
        sessionId: String = UUID().uuidString,
        project: String = "TestProject",
        summary: String = "Test summary",
        keyDecisions: String? = nil,
        keyEntities: String? = nil,
        messageCount: Int = 10,
        archivedAt: String = "2026-02-27 12:00:00"
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation_archive
                        (session_id, project, compressed_summary, key_decisions,
                         key_entities, message_count, archived_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [sessionId, project, summary, keyDecisions,
                            keyEntities, messageCount, archivedAt]
            )
        }
    }

    /// Inserts a knowledge row. The FTS sync trigger auto-updates knowledge_fts.
    private func insertKnowledgeEntry(
        id: String = UUID().uuidString,
        type: String = "pattern",
        title: String = "Test Knowledge",
        content: String = "Test content",
        isActive: Bool = true
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO knowledge (id, type, title, content, is_active)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [id, type, title, content, isActive ? 1 : 0]
            )
        }
    }

    // MARK: - 1. Empty Database

    func testRecallWithEmptyDatabase() {
        let result = sut.recallForMessage(
            "Hello world",
            project: "TestProject",
            sessionId: "session-1"
        )
        XCTAssertEqual(result, "", "Recall should return empty string when no data exists")
    }

    // MARK: - 2. Missing Tables

    func testRecallWithMissingTables() throws {
        // Create a completely blank database — no tables at all
        let blankPath = NSTemporaryDirectory() + "memoryservice-blank-\(UUID().uuidString).sqlite"
        let blankPool = try DatabasePool(path: blankPath)

        // Point DatabaseManager at the blank database
        DatabaseManager.shared.setDatabasePoolForTesting(blankPool)
        MemoryService.resetTableExistsCache()

        let result = sut.recallForMessage(
            "Tell me about authentication",
            project: "BookBuddy",
            sessionId: "session-blank"
        )

        XCTAssertEqual(result, "", "Recall should return empty string when tables don't exist")

        // Cleanup
        try? FileManager.default.removeItem(atPath: blankPath)
        try? FileManager.default.removeItem(atPath: blankPath + "-wal")
        try? FileManager.default.removeItem(atPath: blankPath + "-shm")

        // Restore the test database for remaining tests
        DatabaseManager.shared.setDatabasePoolForTesting(dbPool)
        MemoryService.resetTableExistsCache()
    }

    // MARK: - 3. Exclude Current Session

    func testRecallExcludesCurrentSession() throws {
        let currentSessionId = "session-current"
        let otherSessionId = "session-other"

        // Insert data for the current session — should be excluded
        try insertArchiveEntry(
            sessionId: currentSessionId,
            project: "TestProject",
            summary: "This session should be excluded from recall",
            messageCount: 20,
            archivedAt: "2026-02-27 14:00:00"
        )

        // Insert data for a different session — should appear
        try insertArchiveEntry(
            sessionId: otherSessionId,
            project: "TestProject",
            summary: "This session should appear in recall results",
            messageCount: 15,
            archivedAt: "2026-02-27 13:00:00"
        )

        let result = sut.recallForMessage(
            "testing exclusion",
            project: "TestProject",
            sessionId: currentSessionId
        )

        XCTAssertFalse(
            result.contains("should be excluded"),
            "Current session data should not appear in recall"
        )
        XCTAssertTrue(
            result.contains("should appear"),
            "Other session data should appear in recall"
        )
    }

    // MARK: - 4. Recent Activity Summary

    func testRecentActivitySummary() throws {
        // Insert 3 archived sessions with distinct content
        try insertArchiveEntry(
            sessionId: "session-1",
            project: "Alpha",
            summary: "Implemented authentication flow",
            messageCount: 12,
            archivedAt: "2026-02-25 10:00:00"
        )
        try insertArchiveEntry(
            sessionId: "session-2",
            project: "Beta",
            summary: "Fixed database migration bug",
            messageCount: 8,
            archivedAt: "2026-02-26 10:00:00"
        )
        try insertArchiveEntry(
            sessionId: "session-3",
            project: "Gamma",
            summary: "Added unit test coverage",
            messageCount: 20,
            archivedAt: "2026-02-27 10:00:00"
        )

        let result = sut.recallForMessage(
            "anything",
            project: nil,
            sessionId: "session-other"
        )

        // All 3 sessions should appear in recent activity
        XCTAssertTrue(result.contains("Alpha"), "Session 1 project should appear")
        XCTAssertTrue(result.contains("Beta"), "Session 2 project should appear")
        XCTAssertTrue(result.contains("Gamma"), "Session 3 project should appear")
        XCTAssertTrue(result.contains("Recent Activity"), "Should have Recent Activity section header")
    }

    // MARK: - 5. Project Prioritization

    func testRecentActivityProjectPrioritized() throws {
        // Insert sessions for two projects, with the non-current project having a newer timestamp
        try insertArchiveEntry(
            sessionId: "session-other-proj",
            project: "OtherProject",
            summary: "Work on other project",
            messageCount: 5,
            archivedAt: "2026-02-27 15:00:00"  // Newer
        )
        try insertArchiveEntry(
            sessionId: "session-current-proj",
            project: "CurrentProject",
            summary: "Work on current project",
            messageCount: 10,
            archivedAt: "2026-02-26 10:00:00"  // Older
        )

        let result = sut.recallForMessage(
            "anything",
            project: "CurrentProject",
            sessionId: "session-exclude-me"
        )

        // Current project should appear first despite being older
        guard let currentRange = result.range(of: "CurrentProject"),
              let otherRange = result.range(of: "OtherProject") else {
            XCTFail("Both projects should appear in output")
            return
        }
        XCTAssertTrue(
            currentRange.lowerBound < otherRange.lowerBound,
            "Current project should appear before other projects in the output"
        )
    }

    // MARK: - 6. FTS Query Builder — Stop Words

    func testBuildFTSQueryStopWords() {
        // "the" and "is" and "and" are stop words; "swift" and "concurrency" are not
        let query = sut.buildFTSQuery(from: "the swift is fast and concurrency")

        XCTAssertTrue(query.contains("swift"), "Non-stop word 'swift' should be in query")
        XCTAssertTrue(query.contains("fast"), "Non-stop word 'fast' should be in query")
        XCTAssertTrue(query.contains("concurrency"), "Non-stop word 'concurrency' should be in query")
        XCTAssertFalse(query.contains(" the "), "Stop word 'the' should be removed")
        XCTAssertFalse(query.contains(" and "), "Stop word 'and' should be removed")
    }

    // MARK: - 7. FTS Query Builder — Special Characters

    func testBuildFTSQuerySpecialChars() {
        let query = sut.buildFTSQuery(from: "\"error\" in func(test) -exclude key:value range^2 {block}")

        // Should not contain any FTS5 special characters
        XCTAssertFalse(query.contains("\""), "Double quotes should be stripped")
        XCTAssertFalse(query.contains("*"), "Asterisks should be stripped")
        XCTAssertFalse(query.contains("("), "Open parens should be stripped")
        XCTAssertFalse(query.contains(")"), "Close parens should be stripped")
        XCTAssertFalse(query.contains(":"), "Colons should be stripped")
        XCTAssertFalse(query.contains("^"), "Carets should be stripped")
        XCTAssertFalse(query.contains("{"), "Open braces should be stripped")
        XCTAssertFalse(query.contains("}"), "Close braces should be stripped")

        // Should still contain actual words (that aren't stop words and are >= 3 chars)
        XCTAssertTrue(query.contains("error"), "'error' should survive special char stripping")
        XCTAssertTrue(query.contains("func"), "'func' should survive special char stripping")
        XCTAssertTrue(query.contains("test"), "'test' should survive special char stripping")
        XCTAssertTrue(query.contains("exclude"), "'exclude' should survive special char stripping")
        XCTAssertTrue(query.contains("value"), "'value' should survive special char stripping")
        XCTAssertTrue(query.contains("block"), "'block' should survive special char stripping")
    }

    // MARK: - 8. FTS Query Builder — Max Terms Cap

    func testBuildFTSQueryMaxTerms() {
        // Generate 12 unique words that are all >= 3 chars and not stop words
        let message = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"
        let query = sut.buildFTSQuery(from: message)

        // Count number of OR-separated terms
        let terms = query.components(separatedBy: " OR ")
        XCTAssertEqual(terms.count, 8, "Query should be capped at 8 terms, got \(terms.count)")
    }

    // MARK: - 9. FTS Query Builder — All Stop Words

    func testBuildFTSQueryAllStopWords() {
        let query = sut.buildFTSQuery(from: "the is and was are were been have has had")
        XCTAssertEqual(query, "", "Query of only stop words should return empty string")
    }

    // MARK: - 10. FTS Query Builder — Short Words

    func testBuildFTSQueryShortWords() {
        // All words under 3 characters — should be filtered out
        let query = sut.buildFTSQuery(from: "go to be an if")
        XCTAssertEqual(query, "", "Words under 3 chars should be filtered out")

        // Mix of short and long words
        let mixed = sut.buildFTSQuery(from: "ab swift cd database ef")
        XCTAssertTrue(mixed.contains("swift"), "'swift' (5 chars) should survive")
        XCTAssertTrue(mixed.contains("database"), "'database' (8 chars) should survive")
        XCTAssertFalse(mixed.contains(" ab "), "'ab' (2 chars) should be filtered")
        XCTAssertFalse(mixed.contains(" cd "), "'cd' (2 chars) should be filtered")
        XCTAssertFalse(mixed.contains(" ef "), "'ef' (2 chars) should be filtered")
    }

    // MARK: - 11. Char Budget Respected

    func testCharBudgetRespected() throws {
        // Insert enough archive entries with long summaries to exceed the 8000 char budget
        let longSummary = String(repeating: "This is a long summary with many words about software development. ", count: 20)
        for i in 0..<30 {
            try insertArchiveEntry(
                sessionId: "session-budget-\(i)",
                project: "BudgetProject",
                summary: longSummary,
                keyDecisions: longSummary,
                messageCount: 50,
                archivedAt: "2026-02-\(String(format: "%02d", min(i + 1, 28))) 10:00:00"
            )
        }

        // Also insert knowledge entries that could match
        for i in 0..<20 {
            try insertKnowledgeEntry(
                id: "knowledge-budget-\(i)",
                type: "pattern",
                title: "Software Development Pattern \(i)",
                content: longSummary
            )
        }

        let result = sut.recallForMessage(
            "software development patterns",
            project: "BudgetProject",
            sessionId: "session-exclude"
        )

        // The entire memory block should be under the 8000 char limit
        // Adding some tolerance for the <memory> wrapper tags
        XCTAssertLessThanOrEqual(
            result.count, 8200,
            "Memory block should respect the ~8000 char budget, got \(result.count) chars"
        )
    }

    // MARK: - 12. FTS Search Finds Relevant Content

    func testFTSSearchFindsRelevantContent() throws {
        // Insert entries with specific keywords
        try insertArchiveEntry(
            sessionId: "session-auth",
            project: "BookBuddy",
            summary: "Implemented OAuth authentication with refresh tokens and session management",
            keyDecisions: "Used keychain for token storage",
            messageCount: 15,
            archivedAt: "2026-02-26 10:00:00"
        )
        try insertArchiveEntry(
            sessionId: "session-ui",
            project: "BookBuddy",
            summary: "Redesigned the reading view with custom pagination and font controls",
            messageCount: 8,
            archivedAt: "2026-02-25 10:00:00"
        )

        // Search for authentication — should find the first entry
        let result = sut.recallForMessage(
            "How did we implement authentication?",
            project: "BookBuddy",
            sessionId: "session-exclude"
        )

        XCTAssertTrue(
            result.contains("authentication") || result.contains("OAuth") || result.contains("token"),
            "FTS search should find content matching 'authentication'"
        )
    }

    // MARK: - 13. Knowledge Search Prioritizes Corrections

    func testKnowledgeSearchPrioritizesCorrections() throws {
        // Insert knowledge entries of different types, all mentioning "database"
        try insertKnowledgeEntry(
            id: "k-pattern",
            type: "pattern",
            title: "Database Connection Pattern",
            content: "Always use connection pooling for database access"
        )
        try insertKnowledgeEntry(
            id: "k-decision",
            type: "decision",
            title: "Database Engine Decision",
            content: "Chose SQLite with GRDB for database layer"
        )
        try insertKnowledgeEntry(
            id: "k-correction",
            type: "correction",
            title: "Database Migration Correction",
            content: "Never drop and recreate database tables in migration"
        )
        try insertKnowledgeEntry(
            id: "k-mistake",
            type: "mistake",
            title: "Database Lock Mistake",
            content: "Holding database write lock across await caused deadlock"
        )

        let result = sut.recallForMessage(
            "database migration patterns",
            project: nil,
            sessionId: "session-exclude"
        )

        // The correction should appear before the pattern in the output
        // Knowledge ordering: correction (0) > decision (1) > mistake (2) > pattern (3)
        if let correctionRange = result.range(of: "correction", options: .caseInsensitive),
           let patternRange = result.range(of: "pattern", options: .caseInsensitive) {
            XCTAssertTrue(
                correctionRange.lowerBound < patternRange.lowerBound,
                "Corrections should be prioritized over patterns in knowledge results"
            )
        }

        // At minimum, the result should contain knowledge entries
        let hasKnowledge = result.contains("Database") || result.contains("database")
            || result.contains("migration") || result.contains("SQLite")
        XCTAssertTrue(hasKnowledge, "Knowledge search should return relevant database entries")
    }

    // MARK: - Additional Edge Cases

    func testBuildFTSQueryDeduplicatesTerms() {
        let query = sut.buildFTSQuery(from: "swift swift swift database database")
        let terms = query.components(separatedBy: " OR ")
        XCTAssertEqual(terms.count, 2, "Duplicate terms should be deduplicated")
        XCTAssertTrue(terms.contains("swift"))
        XCTAssertTrue(terms.contains("database"))
    }

    func testBuildFTSQueryEmptyMessage() {
        let query = sut.buildFTSQuery(from: "")
        XCTAssertEqual(query, "", "Empty message should produce empty query")
    }

    func testRecallWithEmptyMessage() throws {
        // Insert data so the DB isn't empty
        try insertArchiveEntry(
            sessionId: "session-1",
            project: "Test",
            summary: "Some past work",
            messageCount: 5,
            archivedAt: "2026-02-27 10:00:00"
        )

        let result = sut.recallForMessage(
            "",
            project: "Test",
            sessionId: "session-exclude"
        )

        // Empty message should still return recent activity (it's query-independent)
        // but should NOT attempt FTS search
        if !result.isEmpty {
            XCTAssertTrue(
                result.contains("Recent Activity"),
                "Empty message recall should still include recent activity"
            )
        }
    }

    func testBuildFTSQueryJoinsWithOR() {
        let query = sut.buildFTSQuery(from: "swift database migration")
        XCTAssertEqual(query, "swift OR database OR migration",
                       "Terms should be joined with ' OR '")
    }

    func testBuildFTSQueryApostropheStripping() {
        // Apostrophes are stripped (not replaced with space), so "don't" becomes "dont"
        let query = sut.buildFTSQuery(from: "don't won't can't")
        // "dont", "wont" are 4 chars and not stop words
        // "cant" is 4 chars and not a stop word
        XCTAssertTrue(query.contains("dont"), "'don't' should become 'dont'")
        XCTAssertTrue(query.contains("wont"), "'won't' should become 'wont'")
        XCTAssertTrue(query.contains("cant"), "'can't' should become 'cant'")
    }
}
