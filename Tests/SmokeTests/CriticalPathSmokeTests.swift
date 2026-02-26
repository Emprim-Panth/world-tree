import XCTest
import GRDB
@testable import WorldTree

// MARK: - Critical Path Smoke Tests

/// Smoke tests for the 5 systems that must never silently break:
/// 1. Database migrations (idempotency, schema integrity)
/// 2. Provider initialization
/// 3. DispatchRouter graceful failure
/// 4. Project context loading
/// 5. Server lifecycle
@MainActor
final class CriticalPathSmokeTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "smoke-test-\(UUID().uuidString).sqlite"
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

    // MARK: - 1. Migration Idempotency

    func testMigrationsRunTwiceWithoutCrash() throws {
        // First run — creates all tables
        try MigrationManager.migrate(dbPool)

        // Second run — should be a no-op (GRDB tracks applied migrations)
        try MigrationManager.migrate(dbPool)

        // Verify core tables exist after double migration
        let tables = try dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table' ORDER BY name
                """)
        }

        XCTAssertTrue(tables.contains("canvas_trees"), "canvas_trees must exist")
        XCTAssertTrue(tables.contains("canvas_branches"), "canvas_branches must exist")
        XCTAssertTrue(tables.contains("canvas_dispatches"), "canvas_dispatches must exist")
        XCTAssertTrue(tables.contains("canvas_project_metrics"), "canvas_project_metrics must exist")
    }

    func testMigrationCreatesAllExpectedTables() throws {
        try MigrationManager.migrate(dbPool)

        let tables = try dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'canvas_%' ORDER BY name
                """)
        }

        let expected: Set<String> = [
            "canvas_trees",
            "canvas_branches",
            "canvas_jobs",
            "canvas_api_state",
            "canvas_dispatches",
            "canvas_project_metrics"
        ]

        for table in expected {
            XCTAssertTrue(tables.contains(table), "Missing expected table: \(table)")
        }
    }

    func testFTS5MigrationSucceeds() throws {
        // FTS5 is critical for search. v12 migration must not silently fail.
        // First create the messages table that FTS5 depends on.
        try dbPool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS messages (
                    id INTEGER PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)
        }

        try MigrationManager.migrate(dbPool)

        // Verify FTS5 table exists
        let hasFTS = try dbPool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master
                WHERE type='table' AND name='messages_fts'
                """)
        }
        XCTAssertEqual(hasFTS, true, "FTS5 table must be created by migration v12")

        // Verify triggers exist
        let triggers = try dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'messages_fts_%'
                """)
        }
        XCTAssertTrue(triggers.contains("messages_fts_ai"), "Insert trigger must exist")
        XCTAssertTrue(triggers.contains("messages_fts_ad"), "Delete trigger must exist")
        XCTAssertTrue(triggers.contains("messages_fts_au"), "Update trigger must exist")
    }

    // MARK: - 2. Provider Initialization

    func testProviderManagerHasActiveProvider() {
        // ProviderManager should always have at least one provider available.
        // In test environment, ClaudeCodeProvider should be registered.
        let pm = ProviderManager.shared
        XCTAssertFalse(pm.activeProviderName.isEmpty, "Active provider name must not be empty")
    }

    func testAgentSDKProviderRegistered() {
        // The AgentSDKProvider must be registered for dispatch to work.
        let pm = ProviderManager.shared
        let provider = pm.provider(withId: "agent-sdk")
        XCTAssertNotNil(provider, "AgentSDKProvider must be registered in ProviderManager")
    }

    // MARK: - 3. DispatchRouter Graceful Failure

    func testDispatchRouterDoesNotCrashOnMissingProvider() {
        // Even if provider lookup fails, dispatch should return an error stream — not crash.
        let context = DispatchContext(
            message: "test",
            project: "TestProject",
            workingDirectory: "/tmp",
            model: nil,
            branchId: nil,
            origin: .ui,
            allowedTools: nil,
            skipPermissions: true,
            systemPromptOverride: nil
        )

        // This should not crash — it should return an error stream or a valid dispatch.
        let (id, _) = DispatchRouter.dispatch(context: context)
        XCTAssertFalse(id.isEmpty, "Dispatch must return a non-empty ID")
    }

    // MARK: - 4. Project Context Loading

    func testProjectCacheGetAllDoesNotCrash() {
        let cache = ProjectCache()
        // Should not crash even if DB hasn't been set up in test environment
        let projects = try? cache.getAll()
        // We just verify it doesn't crash — may return empty or error
        _ = projects
    }

    func testProjectContextLoaderFormatsOutput() async {
        let project = CachedProject(
            path: "/tmp/TestProject",
            name: "TestProject",
            type: .swift,
            gitBranch: "main",
            gitDirty: false,
            lastModified: Date(),
            lastScanned: Date(),
            readme: "A test project for unit testing."
        )

        let context = ProjectContext(
            project: project,
            recentCommits: ["abc1234 Initial commit", "def5678 Add feature"],
            directoryStructure: "📁 Sources/\n📁 Tests/"
        )

        let formatted = context.formatForClaude()

        XCTAssertTrue(formatted.contains("TestProject"), "Must include project name")
        XCTAssertTrue(formatted.contains("Swift"), "Must include project type")
        XCTAssertTrue(formatted.contains("main"), "Must include git branch")
        XCTAssertTrue(formatted.contains("A test project"), "Must include README content")
        XCTAssertTrue(formatted.contains("abc1234"), "Must include recent commits")
        XCTAssertTrue(formatted.contains("Sources"), "Must include directory structure")
    }

    func testProjectContextEmptyFieldsOmitted() async {
        let project = CachedProject(
            path: "/tmp/MinimalProject",
            name: "MinimalProject",
            type: .unknown,
            gitBranch: nil,
            gitDirty: false,
            lastModified: Date(),
            lastScanned: Date(),
            readme: nil
        )

        let context = ProjectContext(
            project: project,
            recentCommits: [],
            directoryStructure: ""
        )

        let formatted = context.formatForClaude()

        XCTAssertTrue(formatted.contains("MinimalProject"), "Must include project name")
        XCTAssertFalse(formatted.contains("README"), "Should not include README section when nil")
        XCTAssertFalse(formatted.contains("Recent Commits"), "Should not include commits section when empty")
        XCTAssertFalse(formatted.contains("Directory Structure"), "Should not include directory section when empty")
    }

    // MARK: - 5. Dispatch Context Validation

    func testDispatchContextRoundTrips() throws {
        try MigrationManager.migrate(dbPool)

        let dispatch = WorldTreeDispatch(
            id: "smoke-test-1",
            project: "WorldTree",
            message: "Run smoke tests",
            model: "sonnet",
            workingDirectory: "/Users/test/Development/WorldTree",
            origin: "ui"
        )

        // Insert
        try dbPool.write { db in try dispatch.insert(db) }

        // Fetch
        let fetched = try dbPool.read { db in
            try WorldTreeDispatch.fetchOne(db, key: "smoke-test-1")
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.project, "WorldTree")
        XCTAssertEqual(fetched?.message, "Run smoke tests")
        XCTAssertEqual(fetched?.model, "sonnet")
        XCTAssertEqual(fetched?.status, .queued)
        XCTAssertEqual(fetched?.origin, "ui")
    }

    // MARK: - 6. WebSocket Client Tracking

    func testSubscriptionManagerLifecycle() {
        let sm = SubscriptionManager.shared
        let clientId = "smoke-\(UUID().uuidString)"
        let branchId = "smoke-branch-\(UUID().uuidString)"

        // Subscribe
        sm.subscribe(clientId: clientId, branchId: branchId)
        XCTAssertTrue(sm.subscribers(for: branchId).contains(clientId))

        // Unsubscribe
        sm.remove(clientId: clientId)
        XCTAssertFalse(sm.subscribers(for: branchId).contains(clientId))
    }
}
