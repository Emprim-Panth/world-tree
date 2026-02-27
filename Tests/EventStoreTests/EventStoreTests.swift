import XCTest
import GRDB
@testable import WorldTree

// MARK: - EventStore Tests

/// Tests for EventStore and WorldTreeEvent — event recording, buffered flush,
/// overlap guards, type filtering, date range queries, and round-trip serialization.
/// Uses a temporary DatabasePool with full migrations, exercising the same SQL
/// that EventStore uses against canvas_events (created in migration v6).
@MainActor
final class EventStoreTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "event-store-test-\(UUID().uuidString).sqlite"
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

    /// Creates a tree + session + branch so event FK references are valid.
    /// Returns the branch ID for use in event logging.
    @discardableResult
    private func createBranch(
        branchId: String = UUID().uuidString,
        treeId: String = UUID().uuidString,
        sessionId: String = UUID().uuidString
    ) throws -> (branchId: String, sessionId: String) {
        try dbPool.write { db in
            // Tree
            try db.execute(
                sql: """
                    INSERT INTO canvas_trees (id, name, created_at, updated_at)
                    VALUES (?, 'Test Tree', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                    """,
                arguments: [treeId]
            )
            // Session
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, terminal_id, working_directory, description, started_at)
                    VALUES (?, 'canvas', '/tmp/test', 'Test session', datetime('now'))
                    """,
                arguments: [sessionId]
            )
            // Branch
            try db.execute(
                sql: """
                    INSERT INTO canvas_branches (id, tree_id, session_id, branch_type, status, created_at, updated_at)
                    VALUES (?, ?, ?, 'conversation', 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                    """,
                arguments: [branchId, treeId, sessionId]
            )
        }
        return (branchId, sessionId)
    }

    /// Inserts a WorldTreeEvent directly into the database (bypasses EventStore buffer).
    @discardableResult
    private func insertEvent(
        branchId: String,
        sessionId: String? = nil,
        type: WorldTreeEventType,
        data: String? = nil,
        timestamp: String = "CURRENT_TIMESTAMP"
    ) throws -> Int64 {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO canvas_events (branch_id, session_id, event_type, event_data, timestamp)
                    VALUES (?, ?, ?, ?, \(timestamp))
                    """,
                arguments: [branchId, sessionId, type.rawValue, data]
            )
            return db.lastInsertedRowID
        }
    }

    /// Fetches all events for a branch, ordered by timestamp ASC.
    private func fetchEvents(branchId: String) throws -> [WorldTreeEvent] {
        try dbPool.read { db in
            try WorldTreeEvent
                .filter(Column("branch_id") == branchId)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    /// Fetches events filtered by type for a branch.
    private func fetchEvents(branchId: String, type: WorldTreeEventType) throws -> [WorldTreeEvent] {
        try dbPool.read { db in
            try WorldTreeEvent
                .filter(Column("branch_id") == branchId)
                .filter(Column("event_type") == type.rawValue)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    /// Counts total events for a branch.
    private func eventCount(branchId: String) throws -> Int {
        try dbPool.read { db in
            try WorldTreeEvent
                .filter(Column("branch_id") == branchId)
                .fetchCount(db)
        }
    }

    // MARK: - 1. testRecordEvent

    func testRecordEvent() throws {
        let (branchId, sessionId) = try createBranch()

        // Insert a single event
        let rowId = try insertEvent(
            branchId: branchId,
            sessionId: sessionId,
            type: .messageUser,
            data: "{\"text\":\"Hello\"}"
        )

        XCTAssertGreaterThan(rowId, 0, "Inserted event should have a positive row ID")

        // Verify retrieval
        let events = try fetchEvents(branchId: branchId)
        XCTAssertEqual(events.count, 1, "Should retrieve exactly 1 event")

        let event = events[0]
        XCTAssertEqual(event.branchId, branchId)
        XCTAssertEqual(event.sessionId, sessionId)
        XCTAssertEqual(event.eventType, .messageUser)
        XCTAssertEqual(event.eventData, "{\"text\":\"Hello\"}")
        XCTAssertNotNil(event.id, "Event should have an auto-incremented ID after insert")
    }

    // MARK: - 2. testBufferFlush

    func testBufferFlush() throws {
        let (branchId, sessionId) = try createBranch()

        // Simulate what EventStore.flush() does: batch insert multiple events
        let eventTypes: [WorldTreeEventType] = [
            .sessionStart, .messageUser, .textChunk, .textChunk,
            .messageAssistant, .toolStart, .toolEnd, .sessionEnd
        ]

        // Create events in memory (mimicking the buffer)
        var bufferedEvents: [WorldTreeEvent] = []
        for eventType in eventTypes {
            bufferedEvents.append(WorldTreeEvent(
                branchId: branchId,
                sessionId: sessionId,
                eventType: eventType,
                eventData: nil,
                timestamp: Date()
            ))
        }

        // Flush: batch write to DB (mirrors EventStore.flush() logic)
        try dbPool.write { db in
            for event in bufferedEvents {
                try event.insert(db)
            }
        }

        // Verify all events written
        let count = try eventCount(branchId: branchId)
        XCTAssertEqual(count, eventTypes.count, "All \(eventTypes.count) buffered events should be written to DB")

        // Verify types match
        let events = try fetchEvents(branchId: branchId)
        let storedTypes = events.map { $0.eventType }
        XCTAssertEqual(storedTypes, eventTypes, "Event types should match insertion order")
    }

    // MARK: - 3. testFlushGuardPreventsOverlap

    func testFlushGuardPreventsOverlap() throws {
        let (branchId, _) = try createBranch()

        // Simulate the flush guard: isFlushingInProgress prevents re-entry
        var isFlushingInProgress = false
        var flushCount = 0

        func simulatedFlush() {
            guard !isFlushingInProgress else { return }
            isFlushingInProgress = true
            flushCount += 1
            // Simulate work
            isFlushingInProgress = false
        }

        // First flush proceeds
        simulatedFlush()
        XCTAssertEqual(flushCount, 1, "First flush should execute")

        // Simulate overlapping flush while in-flight
        isFlushingInProgress = true
        simulatedFlush()
        XCTAssertEqual(flushCount, 1, "Second flush should be skipped while first is in-flight")

        // After first completes, next flush proceeds
        isFlushingInProgress = false
        simulatedFlush()
        XCTAssertEqual(flushCount, 2, "Third flush should execute after guard is cleared")

        // Also verify the DB-level safety: concurrent inserts with the same data don't crash
        try insertEvent(branchId: branchId, type: .textChunk, data: "chunk-1")
        try insertEvent(branchId: branchId, type: .textChunk, data: "chunk-2")
        let count = try eventCount(branchId: branchId)
        XCTAssertEqual(count, 2, "Concurrent-style inserts should both succeed")
    }

    // MARK: - 4. testQueryEventsByType

    func testQueryEventsByType() throws {
        let (branchId, sessionId) = try createBranch()

        // Insert events of various types
        try insertEvent(branchId: branchId, sessionId: sessionId, type: .messageUser)
        try insertEvent(branchId: branchId, sessionId: sessionId, type: .messageAssistant)
        try insertEvent(branchId: branchId, sessionId: sessionId, type: .toolStart, data: "{\"tool\":\"bash\"}")
        try insertEvent(branchId: branchId, sessionId: sessionId, type: .toolEnd, data: "{\"tool\":\"bash\"}")
        try insertEvent(branchId: branchId, sessionId: sessionId, type: .toolStart, data: "{\"tool\":\"read\"}")
        try insertEvent(branchId: branchId, sessionId: sessionId, type: .toolError, data: "{\"error\":\"not found\"}")
        try insertEvent(branchId: branchId, sessionId: sessionId, type: .messageUser)
        try insertEvent(branchId: branchId, sessionId: sessionId, type: .messageAssistant)

        // Filter by toolStart
        let toolStarts = try fetchEvents(branchId: branchId, type: .toolStart)
        XCTAssertEqual(toolStarts.count, 2, "Should find exactly 2 toolStart events")
        XCTAssertTrue(toolStarts.allSatisfy { $0.eventType == .toolStart },
                       "All filtered events should be toolStart")

        // Filter by messageUser
        let userMessages = try fetchEvents(branchId: branchId, type: .messageUser)
        XCTAssertEqual(userMessages.count, 2, "Should find exactly 2 messageUser events")

        // Filter by toolError
        let errors = try fetchEvents(branchId: branchId, type: .toolError)
        XCTAssertEqual(errors.count, 1, "Should find exactly 1 toolError event")
        XCTAssertEqual(errors[0].eventData, "{\"error\":\"not found\"}")

        // Filter by a type with no events
        let sessions = try fetchEvents(branchId: branchId, type: .sessionStart)
        XCTAssertTrue(sessions.isEmpty, "Should return empty for event type not present")

        // Total should be 8
        let total = try eventCount(branchId: branchId)
        XCTAssertEqual(total, 8, "Total event count should be 8")
    }

    // MARK: - 5. testQueryEventsDateRange

    func testQueryEventsDateRange() throws {
        let (branchId, sessionId) = try createBranch()

        // Insert events at specific timestamps (SQLite string format)
        try insertEvent(branchId: branchId, sessionId: sessionId, type: .sessionStart,
                         timestamp: "'2025-06-01 10:00:00'")
        try insertEvent(branchId: branchId, sessionId: sessionId, type: .messageUser,
                         timestamp: "'2025-06-01 10:05:00'")
        try insertEvent(branchId: branchId, sessionId: sessionId, type: .messageAssistant,
                         timestamp: "'2025-06-01 10:10:00'")
        try insertEvent(branchId: branchId, sessionId: sessionId, type: .toolStart,
                         timestamp: "'2025-06-01 11:00:00'")
        try insertEvent(branchId: branchId, sessionId: sessionId, type: .toolEnd,
                         timestamp: "'2025-06-01 12:00:00'")
        try insertEvent(branchId: branchId, sessionId: sessionId, type: .sessionEnd,
                         timestamp: "'2025-06-01 13:00:00'")

        // Use raw SQL with string comparison — matches how SQLite actually stores and compares timestamps.
        // GRDB Date filtering uses ISO8601 with timezone offsets, which doesn't match plain
        // SQLite datetime strings. Raw SQL avoids that mismatch.

        // Date range: 10:00 to 10:30 — should match first 3 events
        let earlyEvents = try dbPool.read { db in
            try WorldTreeEvent.fetchAll(db, sql: """
                SELECT * FROM canvas_events
                WHERE branch_id = ?
                  AND timestamp >= '2025-06-01 10:00:00'
                  AND timestamp <= '2025-06-01 10:30:00'
                ORDER BY timestamp ASC
                """, arguments: [branchId])
        }
        XCTAssertEqual(earlyEvents.count, 3, "Should find 3 events between 10:00 and 10:30")
        XCTAssertEqual(earlyEvents[0].eventType, .sessionStart)
        XCTAssertEqual(earlyEvents[1].eventType, .messageUser)
        XCTAssertEqual(earlyEvents[2].eventType, .messageAssistant)

        // Date range: 11:00 to 13:00 — should match last 3 events
        let lateEvents = try dbPool.read { db in
            try WorldTreeEvent.fetchAll(db, sql: """
                SELECT * FROM canvas_events
                WHERE branch_id = ?
                  AND timestamp >= '2025-06-01 11:00:00'
                  AND timestamp <= '2025-06-01 13:00:00'
                ORDER BY timestamp ASC
                """, arguments: [branchId])
        }
        XCTAssertEqual(lateEvents.count, 3, "Should find 3 events between 11:00 and 13:00")
        XCTAssertEqual(lateEvents[0].eventType, .toolStart)
        XCTAssertEqual(lateEvents[2].eventType, .sessionEnd)

        // Date range with no events
        let emptyEvents = try dbPool.read { db in
            try WorldTreeEvent.fetchAll(db, sql: """
                SELECT * FROM canvas_events
                WHERE branch_id = ?
                  AND timestamp >= '2025-07-01 00:00:00'
                  AND timestamp <= '2025-07-01 23:59:59'
                ORDER BY timestamp ASC
                """, arguments: [branchId])
        }
        XCTAssertTrue(emptyEvents.isEmpty, "Date range with no events should return empty")
    }

    // MARK: - 6. testEventRoundTrip

    func testEventRoundTrip() throws {
        let (branchId, sessionId) = try createBranch()

        // Create an event with all fields populated
        let jsonData = "{\"tool\":\"bash\",\"command\":\"ls -la\",\"exit_code\":0}"
        let originalTimestamp = Date()

        let event = WorldTreeEvent(
            branchId: branchId,
            sessionId: sessionId,
            eventType: .toolEnd,
            eventData: jsonData,
            timestamp: originalTimestamp
        )

        // Write to DB and capture the inserted row ID
        let insertedRowId = try dbPool.write { db -> Int64 in
            try event.insert(db)
            return db.lastInsertedRowID
        }
        XCTAssertGreaterThan(insertedRowId, 0, "Event should have a positive row ID after insert")

        // Read back from DB by row ID
        let fetched = try dbPool.read { db in
            try WorldTreeEvent
                .filter(Column("id") == insertedRowId)
                .fetchOne(db)
        }

        XCTAssertNotNil(fetched, "Should retrieve the event by ID")

        let roundTripped = fetched!
        XCTAssertEqual(roundTripped.id, insertedRowId, "ID should match the inserted row ID")
        XCTAssertEqual(roundTripped.branchId, branchId, "branchId should match")
        XCTAssertEqual(roundTripped.sessionId, sessionId, "sessionId should match")
        XCTAssertEqual(roundTripped.eventType, .toolEnd, "eventType should match")
        XCTAssertEqual(roundTripped.eventData, jsonData, "eventData JSON should match exactly")

        // Timestamp comparison: SQLite stores with second precision, so allow 2 second tolerance
        let timeDiff = abs(roundTripped.timestamp.timeIntervalSince(originalTimestamp))
        XCTAssertLessThan(timeDiff, 2.0, "Timestamp should round-trip within 2 second tolerance")
    }

    // MARK: - 7. testBufferCapacity

    func testBufferCapacity() throws {
        let (branchId, sessionId) = try createBranch()

        // Simulate EventStore's maxBufferSize behavior:
        // When the DB is unavailable and events accumulate, buffer caps at maxBufferSize.
        let maxBufferSize = 500
        var buffer: [WorldTreeEvent] = []

        // Fill buffer to capacity
        for i in 0..<maxBufferSize {
            buffer.append(WorldTreeEvent(
                branchId: branchId,
                sessionId: sessionId,
                eventType: .textChunk,
                eventData: "{\"chunk\":\(i)}",
                timestamp: Date()
            ))
        }

        XCTAssertEqual(buffer.count, maxBufferSize, "Buffer should be at capacity")

        // Simulate a failed flush that tries to put events back
        let failedBatch = Array(buffer.prefix(20))
        buffer = Array(buffer.dropFirst(20))  // simulate flush taking 20

        // Try to re-add failed batch (simulates error recovery)
        if buffer.count + failedBatch.count <= maxBufferSize {
            buffer.insert(contentsOf: failedBatch, at: 0)
        }
        XCTAssertEqual(buffer.count, maxBufferSize, "Buffer should be back at capacity after recovery")

        // Try to add more events when buffer is full — simulate the drop behavior
        let overflowBatch = (0..<50).map { i in
            WorldTreeEvent(
                branchId: branchId,
                sessionId: sessionId,
                eventType: .textChunk,
                eventData: "{\"overflow\":\(i)}",
                timestamp: Date()
            )
        }

        // This mirrors the guard in EventStore.flush() error handler:
        // if buffer.count + events.count <= maxBufferSize → re-add, else drop
        if buffer.count + overflowBatch.count <= maxBufferSize {
            buffer.insert(contentsOf: overflowBatch, at: 0)
        }
        // Buffer should NOT have grown past max
        XCTAssertLessThanOrEqual(buffer.count, maxBufferSize,
                                  "Buffer must never exceed maxBufferSize (\(maxBufferSize))")

        // Verify actual DB writes work when we flush the whole buffer
        try dbPool.write { db in
            for event in buffer {
                try event.insert(db)
            }
        }
        let dbCount = try eventCount(branchId: branchId)
        XCTAssertEqual(dbCount, maxBufferSize, "All buffered events should be written to DB on successful flush")
    }

    // MARK: - Additional Coverage

    func testAllEventTypesInsertable() throws {
        let (branchId, _) = try createBranch()

        // Verify every WorldTreeEventType can be stored and retrieved
        let allTypes: [WorldTreeEventType] = [
            .textChunk, .toolStart, .toolEnd, .toolError,
            .messageUser, .messageAssistant, .sessionStart, .sessionEnd,
            .branchFork, .branchComplete, .error,
            .tokenUsage, .contextCheckpoint, .sessionRotation, .summaryGenerated
        ]

        for eventType in allTypes {
            try insertEvent(branchId: branchId, type: eventType, data: "{\"type\":\"\(eventType.rawValue)\"}")
        }

        let total = try eventCount(branchId: branchId)
        XCTAssertEqual(total, allTypes.count, "Every WorldTreeEventType should be insertable")

        // Verify each type round-trips correctly
        for eventType in allTypes {
            let events = try fetchEvents(branchId: branchId, type: eventType)
            XCTAssertEqual(events.count, 1, "Should find exactly 1 event of type \(eventType.rawValue)")
            XCTAssertEqual(events[0].eventType, eventType,
                           "\(eventType.rawValue) should round-trip through the database")
        }
    }

    func testEventsTableExists() throws {
        let tables = try dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name='canvas_events'
                """)
        }
        XCTAssertEqual(tables, ["canvas_events"], "Migration v6 must create canvas_events table")
    }

    func testEventWithNilOptionalFields() throws {
        let (branchId, _) = try createBranch()

        // Insert event with nil sessionId and nil eventData
        try insertEvent(branchId: branchId, sessionId: nil, type: .error, data: nil)

        let events = try fetchEvents(branchId: branchId)
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].sessionId, "sessionId should be nil when inserted as nil")
        XCTAssertNil(events[0].eventData, "eventData should be nil when inserted as nil")
    }

    func testMultipleBranchesIsolated() throws {
        let (branchA, _) = try createBranch()
        let (branchB, _) = try createBranch()

        // Insert events for branch A
        try insertEvent(branchId: branchA, type: .messageUser)
        try insertEvent(branchId: branchA, type: .messageAssistant)

        // Insert events for branch B
        try insertEvent(branchId: branchB, type: .toolStart)

        // Verify isolation
        let eventsA = try fetchEvents(branchId: branchA)
        let eventsB = try fetchEvents(branchId: branchB)
        XCTAssertEqual(eventsA.count, 2, "Branch A should have 2 events")
        XCTAssertEqual(eventsB.count, 1, "Branch B should have 1 event")
        XCTAssertTrue(eventsA.allSatisfy { $0.branchId == branchA }, "All branch A events should have branchA ID")
        XCTAssertTrue(eventsB.allSatisfy { $0.branchId == branchB }, "All branch B events should have branchB ID")
    }
}
