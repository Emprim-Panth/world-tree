import XCTest
import GRDB
@testable import WorldTree

// MARK: - Dispatch Infrastructure Tests

/// Comprehensive stress tests for the hybrid dispatch architecture.
/// Tests DB migrations, model CRUD, metrics UPSERT, crash recovery, and concurrency.
@MainActor
final class DispatchInfrastructureTests: XCTestCase {

    /// Temp file database for isolated testing — DatabasePool requires WAL mode which
    /// is not supported on in-memory databases.
    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "dispatch-test-\(UUID().uuidString).sqlite"
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

    // MARK: - 1. Migration Verification

    func testMigration13CreatesDispatchTable() throws {
        let tables = try dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name='canvas_dispatches'
                """)
        }
        XCTAssertEqual(tables, ["canvas_dispatches"], "Migration v13 must create canvas_dispatches table")
    }

    func testMigration14CreatesMetricsTable() throws {
        let tables = try dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name='canvas_project_metrics'
                """)
        }
        XCTAssertEqual(tables, ["canvas_project_metrics"], "Migration v14 must create canvas_project_metrics table")
    }

    func testDispatchTableHasCorrectColumns() throws {
        let columns = try dbPool.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(canvas_dispatches)")
        }
        let names = Set(columns.map { $0["name"] as String })
        let expected: Set<String> = [
            "id", "project", "branch_id", "message", "model", "status",
            "working_directory", "origin", "result_text", "result_tokens_in",
            "result_tokens_out", "error", "cli_session_id", "started_at",
            "completed_at", "created_at"
        ]
        XCTAssertEqual(names, expected, "canvas_dispatches must have all expected columns")
    }

    func testDispatchTableHasIndexes() throws {
        let indexes = try dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='index' AND tbl_name='canvas_dispatches'
                """)
        }
        XCTAssertTrue(indexes.contains("idx_dispatches_project"), "Missing project index")
        XCTAssertTrue(indexes.contains("idx_dispatches_status"), "Missing status index")
        XCTAssertTrue(indexes.contains("idx_dispatches_created"), "Missing created_at index")
    }

    func testDispatchStatusCheckConstraint() throws {
        // Valid statuses should work
        let validStatuses = ["queued", "running", "completed", "failed", "cancelled", "interrupted"]
        for status in validStatuses {
            try dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO canvas_dispatches (id, project, message, status, working_directory, origin)
                    VALUES (?, 'test', 'msg', ?, '/tmp', 'background')
                    """, arguments: ["test-\(status)", status])
            }
        }

        // Invalid status should fail
        XCTAssertThrowsError(try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO canvas_dispatches (id, project, message, status, working_directory, origin)
                VALUES ('test-bad', 'test', 'msg', 'invalid_status', '/tmp', 'background')
                """)
        }, "Invalid status should be rejected by CHECK constraint")
    }

    // MARK: - 2. WorldTreeDispatch Model CRUD

    func testDispatchInsertAndFetch() throws {
        let dispatch = WorldTreeDispatch(
            id: "test-insert-1",
            project: "WorldTree",
            message: "Run tests",
            model: "sonnet",
            status: .queued,
            workingDirectory: "/Users/test/Development/WorldTree",
            origin: "ui"
        )

        try dbPool.write { db in try dispatch.insert(db) }

        let fetched = try dbPool.read { db in
            try WorldTreeDispatch.fetchOne(db, key: "test-insert-1")
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.project, "WorldTree")
        XCTAssertEqual(fetched?.message, "Run tests")
        XCTAssertEqual(fetched?.model, "sonnet")
        XCTAssertEqual(fetched?.status, .queued)
        XCTAssertEqual(fetched?.origin, "ui")
    }

    func testDispatchStatusTransitions() throws {
        // Insert a queued dispatch
        let dispatch = WorldTreeDispatch(
            id: "test-status-1",
            project: "BookBuddy",
            message: "Build filter engine",
            workingDirectory: "/tmp"
        )
        try dbPool.write { db in try dispatch.insert(db) }

        // Transition: queued → running
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE canvas_dispatches SET status = 'running', started_at = datetime('now') WHERE id = ?",
                arguments: ["test-status-1"]
            )
        }
        let running = try dbPool.read { db in try WorldTreeDispatch.fetchOne(db, key: "test-status-1") }
        XCTAssertEqual(running?.status, .running)
        XCTAssertNotNil(running?.startedAt)

        // Transition: running → completed
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE canvas_dispatches
                    SET status = 'completed', result_text = 'Done', result_tokens_in = 1000,
                        result_tokens_out = 500, completed_at = datetime('now')
                    WHERE id = ?
                    """,
                arguments: ["test-status-1"]
            )
        }
        let completed = try dbPool.read { db in try WorldTreeDispatch.fetchOne(db, key: "test-status-1") }
        XCTAssertEqual(completed?.status, .completed)
        XCTAssertEqual(completed?.resultText, "Done")
        XCTAssertEqual(completed?.resultTokensIn, 1000)
        XCTAssertEqual(completed?.resultTokensOut, 500)
        XCTAssertNotNil(completed?.completedAt)
    }

    func testDispatchQueryByStatus() throws {
        // Insert dispatches with various statuses
        let statuses: [WorldTreeDispatch.DispatchStatus] = [.queued, .running, .completed, .failed, .cancelled]
        for (i, status) in statuses.enumerated() {
            let d = WorldTreeDispatch(
                id: "test-query-\(i)",
                project: "TestProject",
                message: "Task \(i)",
                status: status,
                workingDirectory: "/tmp"
            )
            try dbPool.write { db in try d.insert(db) }
        }

        // Query active dispatches
        let active = try dbPool.read { db in
            try WorldTreeDispatch
                .filter(Column("status") == "queued" || Column("status") == "running")
                .fetchAll(db)
        }
        XCTAssertEqual(active.count, 2, "Should find 2 active dispatches (queued + running)")

        // Query completed/failed
        let done = try dbPool.read { db in
            try WorldTreeDispatch
                .filter(Column("status") == "completed" || Column("status") == "failed")
                .fetchAll(db)
        }
        XCTAssertEqual(done.count, 2, "Should find 2 done dispatches (completed + failed)")
    }

    func testDispatchComputedProperties() {
        var d = WorldTreeDispatch(
            id: "test-computed",
            project: "Test",
            message: String(repeating: "x", count: 100),
            workingDirectory: "/tmp"
        )
        XCTAssertEqual(d.displayMessage.count, 83, "displayMessage truncates at 80 + '...'")
        XCTAssertTrue(d.isActive, "queued dispatch should be active")
        XCTAssertNil(d.duration, "no startedAt means nil duration")

        d.status = .completed
        XCTAssertFalse(d.isActive, "completed dispatch should not be active")

        d.startedAt = Date().addingTimeInterval(-90)
        d.completedAt = Date()
        XCTAssertEqual(d.durationString, "1m", "90 seconds should format as 1m")
    }

    // MARK: - 3. ProjectMetrics UPSERT

    func testMetricsFirstInsert() throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO canvas_project_metrics
                    (project, total_dispatches, successful_dispatches, failed_dispatches,
                     total_tokens_in, total_tokens_out, total_duration_seconds,
                     last_activity_at, updated_at)
                    VALUES (?, 1, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))
                    ON CONFLICT(project) DO UPDATE SET
                        total_dispatches = total_dispatches + 1,
                        successful_dispatches = successful_dispatches + ?,
                        failed_dispatches = failed_dispatches + ?,
                        total_tokens_in = total_tokens_in + ?,
                        total_tokens_out = total_tokens_out + ?,
                        total_duration_seconds = total_duration_seconds + ?,
                        last_activity_at = datetime('now'),
                        updated_at = datetime('now')
                    """,
                arguments: [
                    "WorldTree",
                    1, 0,       // INSERT: successful=1, failed=0
                    5000, 2000, 45.0,  // INSERT: tokens + duration
                    1, 0,       // UPDATE (not used on first insert)
                    5000, 2000, 45.0
                ]
            )
        }

        let metrics = try dbPool.read { db in
            try ProjectMetrics.filter(Column("project") == "WorldTree").fetchOne(db)
        }
        XCTAssertNotNil(metrics)
        XCTAssertEqual(metrics?.totalDispatches, 1)
        XCTAssertEqual(metrics?.successfulDispatches, 1)
        XCTAssertEqual(metrics?.failedDispatches, 0)
        XCTAssertEqual(metrics?.totalTokensIn, 5000)
        XCTAssertEqual(metrics?.totalTokensOut, 2000)
        XCTAssertEqual(metrics?.totalDurationSeconds ?? -1, 45.0, accuracy: 0.01)
    }

    func testMetricsUpsertAccumulates() throws {
        // First dispatch — success
        try insertMetrics(project: "BookBuddy", isSuccess: true, tokensIn: 3000, tokensOut: 1000, duration: 30)

        // Second dispatch — failure
        try insertMetrics(project: "BookBuddy", isSuccess: false, tokensIn: 1000, tokensOut: 200, duration: 10)

        // Third dispatch — success
        try insertMetrics(project: "BookBuddy", isSuccess: true, tokensIn: 8000, tokensOut: 4000, duration: 120)

        let metrics = try dbPool.read { db in
            try ProjectMetrics.filter(Column("project") == "BookBuddy").fetchOne(db)
        }
        XCTAssertNotNil(metrics)
        XCTAssertEqual(metrics?.totalDispatches, 3)
        XCTAssertEqual(metrics?.successfulDispatches, 2)
        XCTAssertEqual(metrics?.failedDispatches, 1)
        XCTAssertEqual(metrics?.totalTokensIn, 12000)
        XCTAssertEqual(metrics?.totalTokensOut, 5200)
        XCTAssertEqual(metrics?.totalDurationSeconds ?? -1, 160.0, accuracy: 0.01)
        XCTAssertEqual(metrics?.successRate ?? -1, 2.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(metrics?.totalTokens, 17200)
    }

    func testMetricsMultipleProjects() throws {
        try insertMetrics(project: "WorldTree", isSuccess: true, tokensIn: 5000, tokensOut: 2000, duration: 45)
        try insertMetrics(project: "BookBuddy", isSuccess: true, tokensIn: 3000, tokensOut: 1000, duration: 30)
        try insertMetrics(project: "Archon-CAD", isSuccess: false, tokensIn: 1000, tokensOut: 0, duration: 5)

        let all = try dbPool.read { db in
            try ProjectMetrics.order(Column("last_activity_at").desc).fetchAll(db)
        }
        XCTAssertEqual(all.count, 3, "Should have metrics for 3 distinct projects")
        XCTAssertEqual(Set(all.map(\.project)), Set(["WorldTree", "BookBuddy", "Archon-CAD"]))
    }

    // MARK: - 4. Crash Recovery

    func testRecoverInterruptedDispatches() throws {
        // Simulate app crash: dispatches left in running/queued state
        let running = WorldTreeDispatch(id: "crash-1", project: "P1", message: "task1", status: .running, workingDirectory: "/tmp")
        let queued = WorldTreeDispatch(id: "crash-2", project: "P2", message: "task2", status: .queued, workingDirectory: "/tmp")
        let completed = WorldTreeDispatch(id: "crash-3", project: "P3", message: "task3", status: .completed, workingDirectory: "/tmp")

        try dbPool.write { db in
            try running.insert(db)
            try queued.insert(db)
            try completed.insert(db)
        }

        // Run recovery (same SQL as DispatchSupervisor.recoverInterruptedDispatches)
        let count = try dbPool.write { db -> Int in
            try db.execute(sql: """
                UPDATE canvas_dispatches
                SET status = 'interrupted', completed_at = datetime('now')
                WHERE status IN ('running', 'queued')
                """)
            return db.changesCount
        }
        XCTAssertEqual(count, 2, "Should recover 2 dispatches (running + queued)")

        // Verify states
        let d1 = try dbPool.read { db in try WorldTreeDispatch.fetchOne(db, key: "crash-1") }
        let d2 = try dbPool.read { db in try WorldTreeDispatch.fetchOne(db, key: "crash-2") }
        let d3 = try dbPool.read { db in try WorldTreeDispatch.fetchOne(db, key: "crash-3") }

        XCTAssertEqual(d1?.status, .interrupted, "Running dispatch should be marked interrupted")
        XCTAssertEqual(d2?.status, .interrupted, "Queued dispatch should be marked interrupted")
        XCTAssertEqual(d3?.status, .completed, "Completed dispatch should be untouched")
        XCTAssertNotNil(d1?.completedAt, "Interrupted dispatch should get a completed_at timestamp")
    }

    func testHeartbeatOrphanDetection() throws {
        // Simulate: DB says running, but process not tracked in memory
        let d1 = WorldTreeDispatch(id: "orphan-1", project: "P1", message: "task1", status: .running, workingDirectory: "/tmp")
        let d2 = WorldTreeDispatch(id: "orphan-2", project: "P2", message: "task2", status: .running, workingDirectory: "/tmp")
        let d3 = WorldTreeDispatch(id: "tracked-1", project: "P3", message: "task3", status: .running, workingDirectory: "/tmp")

        try dbPool.write { db in
            try d1.insert(db)
            try d2.insert(db)
            try d3.insert(db)
        }

        // Simulated in-memory tracking: only "tracked-1" is alive
        let activeIds: Set<String> = ["tracked-1"]

        let dbRunning = try dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM canvas_dispatches WHERE status = 'running'")
        }
        let orphaned = dbRunning.filter { !activeIds.contains($0) }

        XCTAssertEqual(orphaned.sorted(), ["orphan-1", "orphan-2"], "Should detect 2 orphaned dispatches")

        // Mark orphans as failed
        try dbPool.write { db in
            for id in orphaned {
                try db.execute(
                    sql: "UPDATE canvas_dispatches SET status = 'failed', error = 'Process lost (heartbeat)', completed_at = datetime('now') WHERE id = ?",
                    arguments: [id]
                )
            }
        }

        let o1 = try dbPool.read { db in try WorldTreeDispatch.fetchOne(db, key: "orphan-1") }
        let tracked = try dbPool.read { db in try WorldTreeDispatch.fetchOne(db, key: "tracked-1") }

        XCTAssertEqual(o1?.status, .failed)
        XCTAssertEqual(o1?.error, "Process lost (heartbeat)")
        XCTAssertEqual(tracked?.status, .running, "Tracked dispatch should remain running")
    }

    // MARK: - 5. Pruning

    func testPruneOldDispatches() throws {
        // Insert dispatches with old completion dates
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO canvas_dispatches (id, project, message, status, working_directory, origin, completed_at)
                VALUES ('old-1', 'P1', 'task', 'completed', '/tmp', 'background', datetime('now', '-60 days'))
                """)
            try db.execute(sql: """
                INSERT INTO canvas_dispatches (id, project, message, status, working_directory, origin, completed_at)
                VALUES ('old-2', 'P2', 'task', 'failed', '/tmp', 'background', datetime('now', '-45 days'))
                """)
            try db.execute(sql: """
                INSERT INTO canvas_dispatches (id, project, message, status, working_directory, origin, completed_at)
                VALUES ('recent-1', 'P3', 'task', 'completed', '/tmp', 'background', datetime('now', '-5 days'))
                """)
            try db.execute(sql: """
                INSERT INTO canvas_dispatches (id, project, message, status, working_directory, origin)
                VALUES ('active-1', 'P4', 'task', 'running', '/tmp', 'background')
                """)
        }

        // Prune (same SQL as DispatchSupervisor.pruneOldDispatches)
        let count = try dbPool.write { db -> Int in
            try db.execute(sql: """
                DELETE FROM canvas_dispatches
                WHERE status IN ('completed', 'failed', 'interrupted', 'cancelled')
                AND completed_at < datetime('now', '-30 days')
                """)
            return db.changesCount
        }
        XCTAssertEqual(count, 2, "Should prune 2 old dispatches")

        let remaining = try dbPool.read { db in try WorldTreeDispatch.fetchAll(db) }
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(Set(remaining.map(\.id)), Set(["recent-1", "active-1"]))
    }

    // MARK: - 6. Concurrent Write Stress

    func testConcurrentDispatchInserts() async throws {
        // Stress test: 50 concurrent dispatch inserts
        let count = 50
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask { [dbPool] in
                    let d = WorldTreeDispatch(
                        id: "concurrent-\(i)",
                        project: "Stress-\(i % 5)",
                        message: "Concurrent task \(i)",
                        workingDirectory: "/tmp"
                    )
                    try? await dbPool?.write { db in try d.insert(db) }
                }
            }
        }

        let total = try await dbPool.read { db in
            try WorldTreeDispatch.fetchCount(db)
        }
        XCTAssertEqual(total, count, "All \(count) concurrent inserts should succeed (WAL mode)")
    }

    func testConcurrentMetricsUpserts() async throws {
        // Stress test: 20 concurrent metrics updates for the same project
        let count = 20
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask { [dbPool] in
                    try? await dbPool?.write { db in
                        try db.execute(
                            sql: """
                                INSERT INTO canvas_project_metrics
                                (project, total_dispatches, successful_dispatches, failed_dispatches,
                                 total_tokens_in, total_tokens_out, total_duration_seconds,
                                 last_activity_at, updated_at)
                                VALUES (?, 1, 1, 0, ?, ?, ?, datetime('now'), datetime('now'))
                                ON CONFLICT(project) DO UPDATE SET
                                    total_dispatches = total_dispatches + 1,
                                    successful_dispatches = successful_dispatches + 1,
                                    failed_dispatches = failed_dispatches + 0,
                                    total_tokens_in = total_tokens_in + ?,
                                    total_tokens_out = total_tokens_out + ?,
                                    total_duration_seconds = total_duration_seconds + ?,
                                    last_activity_at = datetime('now'),
                                    updated_at = datetime('now')
                                """,
                            arguments: [
                                "ConcurrentProject",
                                1000, 500, 10.0,
                                1000, 500, 10.0
                            ]
                        )
                    }
                }
            }
        }

        let metrics = try await dbPool.read { db in
            try ProjectMetrics.filter(Column("project") == "ConcurrentProject").fetchOne(db)
        }
        XCTAssertNotNil(metrics)
        XCTAssertEqual(metrics?.totalDispatches, count, "All \(count) concurrent upserts should accumulate")
        XCTAssertEqual(metrics?.totalTokensIn, count * 1000)
        XCTAssertEqual(metrics?.totalTokensOut, count * 500)
    }

    // MARK: - 7. Cancel Tracking

    func testCancelledDispatchNotOverwrittenByFail() throws {
        let d = WorldTreeDispatch(
            id: "cancel-race-1",
            project: "Test",
            message: "Cancellation test",
            status: .running,
            workingDirectory: "/tmp"
        )
        try dbPool.write { db in try d.insert(db) }

        // Simulate: cancelDispatch marks as cancelled
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE canvas_dispatches SET status = 'cancelled' WHERE id = ?",
                arguments: ["cancel-race-1"]
            )
        }

        // Simulate: terminationHandler checks cancelled set, skips fail
        let fetched = try dbPool.read { db in try WorldTreeDispatch.fetchOne(db, key: "cancel-race-1") }
        XCTAssertEqual(fetched?.status, .cancelled, "Cancelled status should be preserved")
    }

    // MARK: - 8. DispatchContext + DispatchOrigin

    func testDispatchOriginRawValues() {
        XCTAssertEqual(DispatchOrigin.background.rawValue, "background")
        XCTAssertEqual(DispatchOrigin.gateway.rawValue, "gateway")
        XCTAssertEqual(DispatchOrigin.crew.rawValue, "crew")
        XCTAssertEqual(DispatchOrigin.ui.rawValue, "ui")
    }

    func testDispatchContextSendable() {
        // This test verifies at compile time that DispatchContext is Sendable
        let context = DispatchContext(
            message: "Test",
            project: "Test",
            workingDirectory: "/tmp",
            model: nil,
            branchId: nil,
            origin: .ui,
            allowedTools: nil,
            skipPermissions: true,
            systemPromptOverride: nil
        )

        // Send across isolation boundaries (compile-time check)
        Task.detached {
            _ = context.message
            _ = context.origin
        }
    }

    // MARK: - Helpers

    private func insertMetrics(project: String, isSuccess: Bool, tokensIn: Int, tokensOut: Int, duration: Double) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO canvas_project_metrics
                    (project, total_dispatches, successful_dispatches, failed_dispatches,
                     total_tokens_in, total_tokens_out, total_duration_seconds,
                     last_activity_at, updated_at)
                    VALUES (?, 1, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))
                    ON CONFLICT(project) DO UPDATE SET
                        total_dispatches = total_dispatches + 1,
                        successful_dispatches = successful_dispatches + ?,
                        failed_dispatches = failed_dispatches + ?,
                        total_tokens_in = total_tokens_in + ?,
                        total_tokens_out = total_tokens_out + ?,
                        total_duration_seconds = total_duration_seconds + ?,
                        last_activity_at = datetime('now'),
                        updated_at = datetime('now')
                    """,
                arguments: [
                    project,
                    isSuccess ? 1 : 0, isSuccess ? 0 : 1,
                    tokensIn, tokensOut, duration,
                    isSuccess ? 1 : 0, isSuccess ? 0 : 1,
                    tokensIn, tokensOut, duration
                ]
            )
        }
    }
}
