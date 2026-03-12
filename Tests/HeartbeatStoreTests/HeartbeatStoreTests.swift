import XCTest
import GRDB
@testable import WorldTree

// MARK: - HeartbeatStore Unit Tests

/// Tests for HeartbeatStore models (HeartbeatRun, HeartbeatSignal, CrewDispatchJob),
/// timestamp parsing, field mapping, and data retrieval via DatabaseManager.
///
/// Uses a temporary database with the heartbeat tables created manually
/// (these tables are created by cortana-cli, not MigrationManager).
@MainActor
final class HeartbeatStoreTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "heartbeat-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)

        // Run canvas migrations (for canvas_dispatches table)
        try MigrationManager.migrate(dbPool)

        // Create heartbeat-specific tables (normally created by cortana-cli)
        try dbPool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS heartbeat_runs (
                    id TEXT PRIMARY KEY,
                    intensity TEXT NOT NULL,
                    started_at TEXT,
                    completed_at TEXT,
                    signals_found INTEGER DEFAULT 0,
                    dispatches_made INTEGER DEFAULT 0,
                    summary TEXT
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS dispatch_queue (
                    id TEXT PRIMARY KEY,
                    project TEXT NOT NULL,
                    model TEXT,
                    crew_agent TEXT,
                    prompt TEXT NOT NULL,
                    ticket_id TEXT,
                    status TEXT NOT NULL DEFAULT 'pending',
                    attempts INTEGER DEFAULT 0,
                    max_attempts INTEGER DEFAULT 3,
                    last_error TEXT,
                    created_at TEXT
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS governance_journal (
                    id TEXT PRIMARY KEY,
                    category TEXT NOT NULL,
                    content TEXT NOT NULL,
                    project TEXT,
                    action_taken TEXT,
                    created_at TEXT
                )
                """)
        }

        DatabaseManager.shared.setDatabasePoolForTesting(dbPool)
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

    // MARK: - 1. HeartbeatRun Model Fields

    func testHeartbeatRunFieldMapping() throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO heartbeat_runs (id, intensity, started_at, completed_at, signals_found, dispatches_made, summary)
                VALUES ('run-1', 'deep', '2026-03-12 10:00:00', '2026-03-12 10:02:30', 8, 3, 'Deep governance check completed')
                """)
        }

        let row = try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM heartbeat_runs WHERE id = 'run-1'")
        }!

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone(identifier: "UTC")

        let run = HeartbeatRun(
            id: row["id"] ?? "",
            intensity: row["intensity"] ?? "unknown",
            startedAt: (row["started_at"] as String?).flatMap { df.date(from: $0) },
            completedAt: (row["completed_at"] as String?).flatMap { df.date(from: $0) },
            signalsFound: row["signals_found"] ?? 0,
            dispatchesMade: row["dispatches_made"] ?? 0,
            summary: row["summary"]
        )

        XCTAssertEqual(run.id, "run-1")
        XCTAssertEqual(run.intensity, "deep")
        XCTAssertEqual(run.signalsFound, 8)
        XCTAssertEqual(run.dispatchesMade, 3)
        XCTAssertEqual(run.summary, "Deep governance check completed")
        XCTAssertNotNil(run.startedAt, "started_at should parse successfully")
        XCTAssertNotNil(run.completedAt, "completed_at should parse successfully")
    }

    // MARK: - 2. Timestamp Parsing

    func testTimestampParsingWithValidDate() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone(identifier: "UTC")

        let date = df.date(from: "2026-03-12 15:30:45")
        XCTAssertNotNil(date)

        let calendar = Calendar(identifier: .gregorian)
        var utcCal = calendar
        utcCal.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = utcCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 12)
        XCTAssertEqual(components.hour, 15)
        XCTAssertEqual(components.minute, 30)
        XCTAssertEqual(components.second, 45)
    }

    func testTimestampParsingWithNilReturnsNil() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let result: Date? = (nil as String?).flatMap { df.date(from: $0) }
        XCTAssertNil(result, "Nil string should produce nil date")
    }

    // MARK: - 3. CrewDispatchJob Model

    func testCrewDispatchJobFieldMapping() throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO dispatch_queue (id, project, model, crew_agent, prompt, ticket_id, status, attempts, max_attempts, last_error, created_at)
                VALUES ('dq-1', 'WorldTree', 'sonnet', 'geordi', 'Fix the build error in TreeStore', 'TASK-100', 'running', 1, 3, NULL, '2026-03-12 14:00:00')
                """)
        }

        let row = try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM dispatch_queue WHERE id = 'dq-1'")
        }!

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone(identifier: "UTC")

        let job = CrewDispatchJob(
            id: row["id"] ?? "",
            project: row["project"] ?? "",
            model: row["model"] ?? "sonnet",
            crewAgent: row["crew_agent"] ?? "unknown",
            prompt: row["prompt"] ?? "",
            ticketId: row["ticket_id"],
            status: row["status"] ?? "unknown",
            attempts: row["attempts"] ?? 0,
            maxAttempts: row["max_attempts"] ?? 3,
            lastError: row["last_error"],
            createdAt: (row["created_at"] as String?).flatMap { df.date(from: $0) }
        )

        XCTAssertEqual(job.id, "dq-1")
        XCTAssertEqual(job.project, "WorldTree")
        XCTAssertEqual(job.model, "sonnet")
        XCTAssertEqual(job.crewAgent, "geordi")
        XCTAssertEqual(job.ticketId, "TASK-100")
        XCTAssertEqual(job.status, "running")
        XCTAssertEqual(job.attempts, 1)
        XCTAssertEqual(job.maxAttempts, 3)
        XCTAssertNil(job.lastError)
    }

    // MARK: - 4. CrewDispatchJob Agent Icons

    func testAgentIconMapping() {
        let geordi = makeJob(crewAgent: "geordi")
        XCTAssertEqual(geordi.agentIcon, "wrench.and.screwdriver")

        let data = makeJob(crewAgent: "data")
        XCTAssertEqual(data.agentIcon, "chart.bar")

        let worf = makeJob(crewAgent: "worf")
        XCTAssertEqual(worf.agentIcon, "shield")

        let torres = makeJob(crewAgent: "torres")
        XCTAssertEqual(torres.agentIcon, "gearshape.2")

        let spock = makeJob(crewAgent: "spock")
        XCTAssertEqual(spock.agentIcon, "brain")

        let unknown = makeJob(crewAgent: "picard")
        XCTAssertEqual(unknown.agentIcon, "person.circle")
    }

    // MARK: - 5. CrewDispatchJob Status Colors

    func testStatusColorMapping() {
        XCTAssertEqual(makeJob(status: "running").statusColor, "blue")
        XCTAssertEqual(makeJob(status: "pending").statusColor, "orange")
        XCTAssertEqual(makeJob(status: "completed").statusColor, "green")
        XCTAssertEqual(makeJob(status: "failed").statusColor, "red")
        XCTAssertEqual(makeJob(status: "other").statusColor, "gray")
    }

    // MARK: - 6. Short Prompt Truncation

    func testShortPromptTruncatesLongPrompts() {
        let longPrompt = String(repeating: "A", count: 120)
        let job = makeJob(prompt: longPrompt)
        XCTAssertTrue(job.shortPrompt.count <= 81, "Short prompt should be at most 80 chars + ellipsis")
        XCTAssertTrue(job.shortPrompt.hasSuffix("\u{2026}"), "Truncated prompt should end with ellipsis")
    }

    func testShortPromptPreservesShortPrompts() {
        let job = makeJob(prompt: "Fix the build")
        XCTAssertEqual(job.shortPrompt, "Fix the build")
    }

    func testShortPromptUsesFirstLine() {
        let job = makeJob(prompt: "First line\nSecond line\nThird line")
        XCTAssertEqual(job.shortPrompt, "First line")
    }

    // MARK: - 7. HeartbeatSignal Model

    func testHeartbeatSignalFieldMapping() throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO governance_journal (id, category, content, project, action_taken, created_at)
                VALUES ('sig-1', 'stale_branch', 'Branch main has 5 stale commits', 'WorldTree', 'Dispatched cleanup', '2026-03-12 09:00:00')
                """)
        }

        let row = try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM governance_journal WHERE id = 'sig-1'")
        }!

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone(identifier: "UTC")

        let signal = HeartbeatSignal(
            id: row["id"] ?? "",
            category: row["category"] ?? "unknown",
            content: row["content"] ?? "",
            project: row["project"],
            actionTaken: row["action_taken"],
            timestamp: (row["created_at"] as String?).flatMap { df.date(from: $0) }
        )

        XCTAssertEqual(signal.id, "sig-1")
        XCTAssertEqual(signal.category, "stale_branch")
        XCTAssertEqual(signal.content, "Branch main has 5 stale commits")
        XCTAssertEqual(signal.project, "WorldTree")
        XCTAssertEqual(signal.actionTaken, "Dispatched cleanup")
        XCTAssertNotNil(signal.timestamp)
    }

    // MARK: - 8. HeartbeatStore Refresh Integration

    func testRefreshLoadsLatestHeartbeatRun() throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO heartbeat_runs (id, intensity, started_at, signals_found, dispatches_made, summary)
                VALUES ('run-old', 'light', '2026-03-12 08:00:00', 2, 0, 'Quick check')
                """)
            try db.execute(sql: """
                INSERT INTO heartbeat_runs (id, intensity, started_at, signals_found, dispatches_made, summary)
                VALUES ('run-new', 'deep', '2026-03-12 12:00:00', 10, 4, 'Full governance cycle')
                """)
        }

        let store = HeartbeatStore.shared
        store.refresh()

        XCTAssertEqual(store.lastIntensity, "deep", "Should load the most recent run by started_at")
        XCTAssertEqual(store.lastSignalCount, 10)
        XCTAssertEqual(store.lastDispatchCount, 4)
        XCTAssertNotNil(store.lastHeartbeat)
    }

    func testRefreshLoadsDispatchJobs() throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO dispatch_queue (id, project, model, crew_agent, prompt, status, created_at)
                VALUES ('dq-a', 'WorldTree', 'sonnet', 'geordi', 'Fix tests', 'running', '2026-03-12 11:00:00')
                """)
            try db.execute(sql: """
                INSERT INTO dispatch_queue (id, project, model, crew_agent, prompt, status, created_at)
                VALUES ('dq-b', 'BookBuddy', 'sonnet', 'data', 'Analyze filters', 'pending', '2026-03-12 11:05:00')
                """)
        }

        let store = HeartbeatStore.shared
        store.refresh()

        XCTAssertEqual(store.dispatchJobs.count, 2, "Should load all dispatch queue jobs")
        // Running should sort first
        XCTAssertEqual(store.dispatchJobs.first?.status, "running",
                       "Running jobs should appear first in sort order")
    }

    func testRefreshLoadsGovernanceSignals() throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO governance_journal (id, category, content, project, created_at)
                VALUES ('s1', 'stale_branch', 'Branch is stale', 'WorldTree', '2026-03-12 10:00:00')
                """)
            try db.execute(sql: """
                INSERT INTO governance_journal (id, category, content, project, created_at)
                VALUES ('s2', 'stuck_terminal', 'Terminal not responding', NULL, '2026-03-12 10:05:00')
                """)
        }

        let store = HeartbeatStore.shared
        store.refresh()

        XCTAssertEqual(store.recentSignals.count, 2)
        // Most recent first
        XCTAssertEqual(store.recentSignals.first?.category, "stuck_terminal")
    }

    func testRefreshLoadsActiveDispatches() throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO canvas_dispatches (id, project, message, working_directory, status)
                VALUES ('cd-1', 'WorldTree', 'Task A', '/tmp', 'running')
                """)
            try db.execute(sql: """
                INSERT INTO canvas_dispatches (id, project, message, working_directory, status)
                VALUES ('cd-2', 'WorldTree', 'Task B', '/tmp', 'queued')
                """)
            try db.execute(sql: """
                INSERT INTO canvas_dispatches (id, project, message, working_directory, status)
                VALUES ('cd-3', 'WorldTree', 'Task C', '/tmp', 'completed')
                """)
        }

        let store = HeartbeatStore.shared
        store.refresh()

        XCTAssertEqual(store.activeDispatches, 2,
                       "Should count only queued and running dispatches")
    }

    func testRefreshLoadsRecentRuns() throws {
        // Insert 12 runs — should only load 10
        for i in 1...12 {
            try dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO heartbeat_runs (id, intensity, started_at, signals_found, dispatches_made)
                    VALUES (?, 'light', ?, 1, 0)
                    """, arguments: ["run-\(i)", "2026-03-12 \(String(format: "%02d", i)):00:00"])
            }
        }

        let store = HeartbeatStore.shared
        store.refresh()

        XCTAssertEqual(store.recentRuns.count, 10, "Should limit to 10 recent runs")
        // Most recent first
        XCTAssertEqual(store.recentRuns.first?.id, "run-12")
    }

    // MARK: - Helpers

    private func makeJob(
        crewAgent: String = "geordi",
        status: String = "pending",
        prompt: String = "Do something"
    ) -> CrewDispatchJob {
        CrewDispatchJob(
            id: UUID().uuidString,
            project: "TestProject",
            model: "sonnet",
            crewAgent: crewAgent,
            prompt: prompt,
            ticketId: nil,
            status: status,
            attempts: 0,
            maxAttempts: 3,
            lastError: nil,
            createdAt: Date()
        )
    }
}
