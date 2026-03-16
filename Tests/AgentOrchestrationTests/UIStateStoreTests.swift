import XCTest
import GRDB
@testable import WorldTree

// MARK: - UI State Store Tests

@MainActor
final class UIStateStoreTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "uistate-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)
        try MigrationManager.migrate(dbPool)
    }

    override func tearDown() async throws {
        dbPool = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        try await super.tearDown()
    }

    // MARK: - Set + Get Round-Trip (String)

    func testStringRoundTrip() throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO ui_state (key, value, updated_at)
                VALUES ('test.key', 'hello', datetime('now'))
                """)
        }

        let value = try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM ui_state WHERE key = ?", arguments: ["test.key"])
        }

        XCTAssertEqual(value, "hello")
    }

    // MARK: - Set + Get Round-Trip (Bool)

    func testBoolRoundTrip() throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO ui_state (key, value, updated_at)
                VALUES ('test.bool', 'true', datetime('now'))
                """)
        }

        let value = try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM ui_state WHERE key = ?", arguments: ["test.bool"])
        }

        XCTAssertEqual(value, "true")
    }

    // MARK: - Missing Key Returns Nil

    func testMissingKeyReturnsNil() throws {
        let value = try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM ui_state WHERE key = ?", arguments: ["nonexistent"])
        }

        XCTAssertNil(value)
    }

    // MARK: - Overwrite Replaces Value

    func testOverwriteReplacesValue() throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO ui_state (key, value, updated_at)
                VALUES ('test.overwrite', 'first', datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO ui_state (key, value, updated_at)
                VALUES ('test.overwrite', 'second', datetime('now'))
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """)
        }

        let value = try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM ui_state WHERE key = ?", arguments: ["test.overwrite"])
        }

        XCTAssertEqual(value, "second")
    }

    // MARK: - Multiple Keys

    func testMultipleKeys() throws {
        try dbPool.write { db in
            try db.execute(sql: "INSERT INTO ui_state (key, value) VALUES ('a', '1')")
            try db.execute(sql: "INSERT INTO ui_state (key, value) VALUES ('b', '2')")
            try db.execute(sql: "INSERT INTO ui_state (key, value) VALUES ('c', '3')")
        }

        let count = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ui_state")
        }

        XCTAssertEqual(count, 3)
    }
}
