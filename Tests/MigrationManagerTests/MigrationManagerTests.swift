import XCTest
import GRDB
@testable import WorldTree

// MARK: - MigrationManager Unit Tests

/// Verifies all 22 migrations are idempotent, create the expected tables and indexes,
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

        // Running again should be a no-op — GRDB tracks applied migrations
        XCTAssertNoThrow(try MigrationManager.migrate(dbPool),
                         "Migrations must be idempotent — running twice should not error")
    }

    // MARK: - 3. Core Tables Created (v1)

    func testV1CreatesCanvasTreesAndBranches() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try tableExists("canvas_trees"), "canvas_trees should exist after v1")
        XCTAssertTrue(try tableExists("canvas_branches"), "canvas_branches should exist after v1")
        XCTAssertTrue(try tableExists("canvas_branch_tags"), "canvas_branch_tags should exist after v1")

        // Verify key indexes
        XCTAssertTrue(try indexExists("idx_branches_tree"), "idx_branches_tree index should exist")
        XCTAssertTrue(try indexExists("idx_branches_parent"), "idx_branches_parent index should exist")
        XCTAssertTrue(try indexExists("idx_branches_session"), "idx_branches_session index should exist")
        XCTAssertTrue(try indexExists("idx_trees_project"), "idx_trees_project index should exist")
    }

    // MARK: - 4. API State and Token Tracking (v2)

    func testV2CreatesApiStateAndTokenUsage() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try tableExists("canvas_api_state"), "canvas_api_state should exist after v2")
        XCTAssertTrue(try tableExists("canvas_token_usage"), "canvas_token_usage should exist after v2")
    }

    // MARK: - 5. Job Queue (v3)

    func testV3CreatesJobQueue() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try tableExists("canvas_jobs"), "canvas_jobs should exist after v3")
        XCTAssertTrue(try indexExists("idx_jobs_status"), "idx_jobs_status index should exist")
    }

    // MARK: - 6. Standalone Core Tables (v11)

    func testV11CreatesSessionsAndMessages() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try tableExists("sessions"), "sessions should exist after v11")
        XCTAssertTrue(try tableExists("messages"), "messages should exist after v11")
    }

    // MARK: - 7. FTS5 with Porter Stemming (v12)

    func testV12CreatesFTS5WithTriggers() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try tableExists("messages_fts"), "messages_fts should exist after v12")

        // Verify sync triggers exist
        let hasTrigger = try dbPool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master
                WHERE type='trigger' AND name='messages_fts_ai'
                """) ?? false
        }
        XCTAssertTrue(hasTrigger, "messages_fts_ai trigger should exist for FTS sync")
    }

    // MARK: - 8. Dispatches Table (v13)

    func testV13CreatesDispatchesTable() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try tableExists("canvas_dispatches"), "canvas_dispatches should exist after v13")
        XCTAssertTrue(try indexExists("idx_dispatches_status"), "idx_dispatches_status index should exist")
    }

    // MARK: - 9. Denormalized Sidebar Stats (v17)

    func testV17AddsDenormalizedColumnsToTrees() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try columnExists(table: "canvas_trees", column: "message_count"),
                      "canvas_trees should have message_count column after v17")
        XCTAssertTrue(try columnExists(table: "canvas_trees", column: "last_message_at"),
                      "canvas_trees should have last_message_at column after v17")
        XCTAssertTrue(try columnExists(table: "canvas_trees", column: "last_assistant_snippet"),
                      "canvas_trees should have last_assistant_snippet column after v17")
    }

    // MARK: - 10. Security Approvals (v18)

    func testV18CreatesSecurityApprovalsTable() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try tableExists("canvas_security_approvals"),
                      "canvas_security_approvals should exist after v18")
    }

    // MARK: - 11. Branch Columns Added (v8, v20)

    func testBranchColumnsAdded() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try columnExists(table: "canvas_branches", column: "tmux_session_name"),
                      "canvas_branches should have tmux_session_name after v8")
        XCTAssertTrue(try columnExists(table: "canvas_branches", column: "compaction_mode"),
                      "canvas_branches should have compaction_mode after v20")
    }

    // MARK: - 12. Tickets Table (v21)

    func testV21CreatesTicketsTable() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try tableExists("canvas_tickets"), "canvas_tickets should exist after v21")
        XCTAssertTrue(try indexExists("idx_canvas_tickets_project"),
                      "idx_canvas_tickets_project index should exist")
    }

    // MARK: - 13. Pencil Assets (v22)

    func testV22CreatesPenAssetTables() throws {
        try MigrationManager.migrate(dbPool)

        XCTAssertTrue(try tableExists("pen_assets"), "pen_assets should exist after v22")
        XCTAssertTrue(try tableExists("pen_frame_links"), "pen_frame_links should exist after v22")
    }

    // MARK: - 14. CHECK Constraints

    func testBranchTypeCheckConstraint() throws {
        try MigrationManager.migrate(dbPool)

        // Insert a tree first (FK target)
        try dbPool.write { db in
            try db.execute(sql: "INSERT INTO canvas_trees (id, name) VALUES ('t1', 'Test')")
        }

        // Valid branch type should succeed
        XCTAssertNoThrow(try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO canvas_branches (id, tree_id, branch_type, status)
                VALUES ('b1', 't1', 'conversation', 'active')
                """)
        })

        // Invalid branch type should fail
        XCTAssertThrowsError(try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO canvas_branches (id, tree_id, branch_type, status)
                VALUES ('b2', 't1', 'invalid_type', 'active')
                """)
        }, "Invalid branch_type should violate CHECK constraint")
    }

    func testBranchStatusCheckConstraint() throws {
        try MigrationManager.migrate(dbPool)

        try dbPool.write { db in
            try db.execute(sql: "INSERT INTO canvas_trees (id, name) VALUES ('t1', 'Test')")
        }

        // Invalid status should fail
        XCTAssertThrowsError(try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO canvas_branches (id, tree_id, branch_type, status)
                VALUES ('b1', 't1', 'conversation', 'bogus_status')
                """)
        }, "Invalid status should violate CHECK constraint")
    }

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

    // MARK: - 15. Unique Constraints

    func testPenAssetsFilePathUnique() throws {
        try MigrationManager.migrate(dbPool)

        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO pen_assets (id, project, file_path, file_name)
                VALUES ('pa1', 'TestProj', '/path/to/file.pen', 'file.pen')
                """)
        }

        XCTAssertThrowsError(try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO pen_assets (id, project, file_path, file_name)
                VALUES ('pa2', 'TestProj', '/path/to/file.pen', 'file.pen')
                """)
        }, "Duplicate file_path should violate UNIQUE constraint")
    }
}
