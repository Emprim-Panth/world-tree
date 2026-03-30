import XCTest
import GRDB
@testable import WorldTree

// MARK: - DatabaseManager Unit Tests

/// Tests for DatabaseManager — connection lifecycle, PRAGMA verification, path resolution,
/// read/write guards, and WAL checkpoint timer management.
///
/// Uses setDatabasePoolForTesting() to inject temporary databases without touching production.
@MainActor
final class DatabaseManagerTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "dbmanager-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)
        try MigrationManager.migrate(dbPool)
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

    // MARK: - 1. Double-Init Guard

    func testDoubleInitGuard() throws {
        // After setting a pool, calling setup() should not replace it
        DatabaseManager.shared.setDatabasePoolForTesting(dbPool)
        let originalPool = DatabaseManager.shared.dbPool

        // setup() checks `guard dbPool == nil` — since we set one, it should no-op
        try DatabaseManager.shared.setup()

        XCTAssertTrue(DatabaseManager.shared.dbPool === originalPool,
                       "setup() should not replace an existing dbPool")
    }

    // MARK: - 2. Read/Write Error When Disconnected

    func testReadThrowsWhenDisconnected() {
        // Ensure dbPool is nil
        DatabaseManager.shared.setDatabasePoolForTesting(nil)

        XCTAssertThrowsError(try DatabaseManager.shared.read { _ in 42 }) { error in
            XCTAssertTrue(error is WorldTree.DatabaseError,
                          "Should throw DatabaseError.notConnected")
        }
    }

    func testWriteThrowsWhenDisconnected() {
        DatabaseManager.shared.setDatabasePoolForTesting(nil)

        XCTAssertThrowsError(try DatabaseManager.shared.write { _ in 42 }) { error in
            XCTAssertTrue(error is WorldTree.DatabaseError,
                          "Should throw DatabaseError.notConnected")
        }
    }

    func testAsyncReadThrowsWhenDisconnected() async {
        DatabaseManager.shared.setDatabasePoolForTesting(nil)

        do {
            _ = try await DatabaseManager.shared.asyncRead { _ in 42 }
            XCTFail("asyncRead should throw when disconnected")
        } catch {
            XCTAssertTrue(error is WorldTree.DatabaseError)
        }
    }

    func testAsyncWriteThrowsWhenDisconnected() async {
        DatabaseManager.shared.setDatabasePoolForTesting(nil)

        do {
            _ = try await DatabaseManager.shared.asyncWrite { _ in 42 }
            XCTFail("asyncWrite should throw when disconnected")
        } catch {
            XCTAssertTrue(error is WorldTree.DatabaseError)
        }
    }

    // MARK: - 3. Read/Write Success When Connected

    func testReadSucceedsWhenConnected() throws {
        DatabaseManager.shared.setDatabasePoolForTesting(dbPool)

        let result = try DatabaseManager.shared.read { db in
            try Int.fetchOne(db, sql: "SELECT 1")
        }
        XCTAssertEqual(result, 1, "read() should execute SQL and return result")
    }

    func testWriteSucceedsWhenConnected() throws {
        DatabaseManager.shared.setDatabasePoolForTesting(dbPool)

        // Write a dispatch row
        try DatabaseManager.shared.write { db in
            try db.execute(sql: """
                INSERT INTO canvas_dispatches (id, project, message, working_directory, status)
                VALUES ('test-dispatch', 'TestProject', 'Test message', '/tmp', 'queued')
                """)
        }

        // Verify it persisted
        let count = try DatabaseManager.shared.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM canvas_dispatches WHERE id = 'test-dispatch'")
        }
        XCTAssertEqual(count, 1, "write() should persist data")
    }

    // MARK: - 4. PRAGMA Verification

    func testPragmaWALMode() throws {
        // Create a pool with the same PRAGMA config as DatabaseManager.setup()
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 100")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        let testPath = NSTemporaryDirectory() + "pragma-test-\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: testPath)
            try? FileManager.default.removeItem(atPath: testPath + "-wal")
            try? FileManager.default.removeItem(atPath: testPath + "-shm")
        }

        let pool = try DatabasePool(path: testPath, configuration: config)

        let journalMode = try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(journalMode, "wal", "Journal mode should be WAL")

        let fk = try pool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        XCTAssertEqual(fk, 1, "Foreign keys should be enabled")

        let timeout = try pool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA busy_timeout")
        }
        XCTAssertEqual(timeout, 5000, "Busy timeout should be 5000ms")

        let autocheckpoint = try pool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA wal_autocheckpoint")
        }
        XCTAssertEqual(autocheckpoint, 100, "WAL autocheckpoint should be 100 pages")

        let sync = try pool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA synchronous")
        }
        // NORMAL = 1
        XCTAssertEqual(sync, 1, "Synchronous should be NORMAL (1)")
    }

    // MARK: - 5. Checkpoint Timer Lifecycle

    func testStopCheckpointTimerCleansUp() {
        DatabaseManager.shared.setDatabasePoolForTesting(dbPool)

        // stopCheckpointTimer should not crash when called multiple times
        DatabaseManager.shared.stopCheckpointTimer()
        DatabaseManager.shared.stopCheckpointTimer()
        // No assertion needed — just verifying it doesn't crash or throw
    }

    func testSetDatabasePoolForTestingStopsTimer() {
        // Setting a pool and then nil should stop the timer gracefully
        DatabaseManager.shared.setDatabasePoolForTesting(dbPool)
        DatabaseManager.shared.setDatabasePoolForTesting(nil)

        XCTAssertNil(DatabaseManager.shared.dbPool,
                     "setDatabasePoolForTesting(nil) should clear the pool")
    }

    // MARK: - 6. DatabaseError Description

    func testDatabaseErrorDescription() {
        let error = DatabaseError.notConnected
        XCTAssertEqual(error.errorDescription, "Database not connected. Call DatabaseManager.setup() first.")
    }
}
