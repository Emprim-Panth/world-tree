import XCTest
import GRDB
@testable import WorldTree

// MARK: - MigrationManager Unit Tests

/// Verifies all migrations are idempotent, create the expected tables and indexes,
/// and enforce schema constraints. Each test gets a fresh temporary database.
@MainActor
final class MigrationManagerTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "migration-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)
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

    private func tableExists(_ name: String) throws -> Bool {
        try dbPool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name=?
                """, arguments: [name]) ?? false
        }
    }

    private func indexExists(_ name: String) throws -> Bool {
        try dbPool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='index' AND name=?
                """, arguments: [name]) ?? false
        }
    }

    private func columnExists(table: String, column: String) throws -> Bool {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            return rows.contains { ($0["name"] as String) == column }
        }
    }

    // MARK: - 1. Migrations Run Without Error

    func testMigrationsCompleteSuccessfully() throws {
        XCTAssertNoThrow(try MigrationManager.migrate(dbPool),
                         "All migrations should complete without error")
    }

    // MARK: - 2. Idempotency — Running Twice Succeeds

    func testMigrationsAreIdempotent() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertNoThrow(try MigrationManager.migrate(dbPool),
                         "Migrations must be idempotent — running twice should not error")
    }

    // MARK: - 3. Dispatches Table (v13)

    func testV13CreatesDispatchesTable() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try tableExists("canvas_dispatches"), "canvas_dispatches should exist after v13")
        XCTAssertTrue(try indexExists("idx_dispatches_status"), "idx_dispatches_status index should exist")
        XCTAssertTrue(try indexExists("idx_dispatches_project"), "idx_dispatches_project index should exist")
        XCTAssertTrue(try indexExists("idx_dispatches_created"), "idx_dispatches_created index should exist")
    }

    // MARK: - 4. Tickets Table (v21)

    func testV21CreatesTicketsTable() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try tableExists("canvas_tickets"), "canvas_tickets should exist after v21")
        XCTAssertTrue(try indexExists("idx_canvas_tickets_project"),
                      "idx_canvas_tickets_project index should exist")
        XCTAssertTrue(try indexExists("idx_canvas_tickets_priority"),
                      "idx_canvas_tickets_priority index should exist")
    }

    // MARK: - 5. Chat Tables Dropped (v29)

    func testV29DropsChatTables() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertFalse(try tableExists("canvas_trees"), "canvas_trees should be dropped after v29")
        XCTAssertFalse(try tableExists("canvas_branches"), "canvas_branches should be dropped after v29")
        XCTAssertFalse(try tableExists("canvas_jobs"), "canvas_jobs should be dropped after v29")
        XCTAssertFalse(try tableExists("pen_assets"), "pen_assets should be dropped after v29")
        XCTAssertFalse(try tableExists("pen_frame_links"), "pen_frame_links should be dropped after v29")
    }

    // MARK: - 6. Agent Workspace (v30)

    func testV30CreatesAgentWorkspaceTables() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try tableExists("agent_sessions"), "agent_sessions should exist after v30")
        XCTAssertTrue(try tableExists("agent_screenshots"), "agent_screenshots should exist after v30")
        XCTAssertTrue(try indexExists("idx_agent_sessions_project"), "idx_agent_sessions_project should exist")
        XCTAssertTrue(try indexExists("idx_agent_screenshots_session"), "idx_agent_screenshots_session should exist")
    }

    // MARK: - 7. Agent Columns Patched (v31)

    func testV31PatchesAgentSessionColumns() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try columnExists(table: "agent_sessions", column: "task"),
                      "agent_sessions should have task column after v31")
        XCTAssertTrue(try columnExists(table: "agent_sessions", column: "build_status"),
                      "agent_sessions should have build_status column after v31")
        XCTAssertTrue(try columnExists(table: "agent_sessions", column: "proof_path"),
                      "agent_sessions should have proof_path column after v31")
    }

    // MARK: - 8. Inference Log (v35)

    func testV35CreatesInferenceLog() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try tableExists("inference_log"), "inference_log should exist after v35")
        XCTAssertTrue(try indexExists("idx_inference_log_date"), "idx_inference_log_date should exist")
        XCTAssertTrue(try indexExists("idx_inference_log_provider"), "idx_inference_log_provider should exist")
    }

    // MARK: - 9. Dispatch Status CHECK Constraint

    func testDispatchStatusCheckConstraint() throws {
        try MigrationManager.migrate(dbPool)

        // Valid status
        XCTAssertNoThrow(try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO canvas_dispatches (id, project, message, working_directory, status)
                VALUES ('d1', 'TestProj', 'Do something', '/tmp', 'queued')
                """)
        })

        // Invalid status
        XCTAssertThrowsError(try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO canvas_dispatches (id, project, message, working_directory, status)
                VALUES ('d2', 'TestProj', 'Do something', '/tmp', 'invalid_status')
                """)
        }, "Invalid dispatch status should violate CHECK constraint")
    }

    // MARK: - 10. Inference Log Insert Round-Trip

    func testInferenceLogInsertAndRead() throws {
        try MigrationManager.migrate(dbPool)

        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO inference_log (task_type, provider, input_tokens, output_tokens, latency_ms, confidence)
                VALUES ('code_review', 'ollama-72b', 1500, 800, 2300, 'high')
                """)
        }

        let count = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inference_log WHERE provider = 'ollama-72b'")
        }
        XCTAssertEqual(count, 1, "Inference log should persist routing entries")
    }
}
