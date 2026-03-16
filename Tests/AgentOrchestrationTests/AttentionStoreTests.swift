import XCTest
import GRDB
@testable import WorldTree

// MARK: - Attention Store Tests

@MainActor
final class AttentionStoreTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "attention-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)
        try MigrationManager.migrate(dbPool)
    }

    override func tearDown() async throws {
        dbPool = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        try await super.tearDown()
    }

    // MARK: - Event Insert + Fetch

    func testEventInsertAndFetch() throws {
        let event = AttentionEvent(
            id: "evt-1",
            sessionId: "session-1",
            type: .errorLoop,
            severity: .warning,
            message: "Agent hit 3 consecutive errors"
        )

        try dbPool.write { db in try event.insert(db) }

        let fetched = try dbPool.read { db in
            try AttentionEvent.fetchOne(db, sql: "SELECT * FROM agent_attention_events WHERE id = ?", arguments: ["evt-1"])
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.type, .errorLoop)
        XCTAssertEqual(fetched?.severity, .warning)
        XCTAssertTrue(fetched?.isUnacknowledged ?? false)
    }

    // MARK: - Acknowledge

    func testAcknowledge() throws {
        let event = AttentionEvent(
            id: "evt-ack",
            sessionId: "session-1",
            type: .stuck,
            severity: .warning,
            message: "Session stuck"
        )
        try dbPool.write { db in try event.insert(db) }

        // Acknowledge
        try dbPool.write { db in
            try db.execute(sql: """
                UPDATE agent_attention_events
                SET acknowledged = 1, acknowledged_at = datetime('now')
                WHERE id = ?
                """, arguments: ["evt-ack"])
        }

        let fetched = try dbPool.read { db in
            try AttentionEvent.fetchOne(db, sql: "SELECT * FROM agent_attention_events WHERE id = ?", arguments: ["evt-ack"])
        }

        XCTAssertNotNil(fetched)
        XCTAssertFalse(fetched?.isUnacknowledged ?? true)
    }

    // MARK: - Severity Ordering

    func testSortBySeverityThenRecency() throws {
        let events = [
            AttentionEvent(id: "info-old", sessionId: "s1", type: .completed, severity: .info, message: "Done"),
            AttentionEvent(id: "warn-old", sessionId: "s1", type: .errorLoop, severity: .warning, message: "Errors"),
            AttentionEvent(id: "crit-new", sessionId: "s1", type: .stuck, severity: .critical, message: "Critical"),
        ]

        try dbPool.write { db in
            for event in events { try event.insert(db) }
        }

        let fetched = try dbPool.read { db in
            try AttentionEvent.fetchAll(db, sql: """
                SELECT * FROM agent_attention_events
                ORDER BY
                    CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END,
                    created_at DESC
                """)
        }

        XCTAssertEqual(fetched.count, 3)
        XCTAssertEqual(fetched.first?.severity, .critical)
    }

    // MARK: - Critical Count

    func testCriticalCount() throws {
        let events = [
            AttentionEvent(id: "c1", sessionId: "s1", type: .stuck, severity: .critical, message: "A"),
            AttentionEvent(id: "c2", sessionId: "s1", type: .stuck, severity: .critical, message: "B"),
            AttentionEvent(id: "w1", sessionId: "s1", type: .errorLoop, severity: .warning, message: "C"),
        ]

        try dbPool.write { db in
            for event in events { try event.insert(db) }
        }

        let criticalCount = try dbPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM agent_attention_events
                WHERE severity = 'critical' AND acknowledged = 0
                """)
        }

        XCTAssertEqual(criticalCount, 2)
    }
}
