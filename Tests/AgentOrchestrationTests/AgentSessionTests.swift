import XCTest
import GRDB
@testable import WorldTree

// MARK: - Agent Session Tests

@MainActor
final class AgentSessionTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "agent-session-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)
        try MigrationManager.migrate(dbPool)
    }

    override func tearDown() async throws {
        dbPool = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        try await super.tearDown()
    }

    // MARK: - Insert + Fetch Round-Trip

    func testInsertAndFetch() throws {
        let session = AgentSession(
            id: "test-session-1",
            agentName: "geordi",
            project: "WorldTree",
            workingDirectory: "/Users/test/Development/WorldTree",
            source: "dispatch",
            status: .thinking,
            startedAt: Date(),
            tokensIn: 5000,
            tokensOut: 1500,
            contextUsed: 80000,
            contextMax: 200000,
            filesChanged: "[\"file1.swift\",\"file2.swift\"]"
        )

        try dbPool.write { db in
            try session.insert(db)
        }

        let fetched = try dbPool.read { db in
            try AgentSession.fetchOne(db, sql: "SELECT * FROM agent_sessions WHERE id = ?", arguments: ["test-session-1"])
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.agentName, "geordi")
        XCTAssertEqual(fetched?.project, "WorldTree")
        XCTAssertEqual(fetched?.status, .thinking)
        XCTAssertEqual(fetched?.tokensIn, 5000)
        XCTAssertEqual(fetched?.tokensOut, 1500)
    }

    // MARK: - Status Enum Mapping

    func testAllStatusValues() throws {
        let statuses: [AgentSessionStatus] = [
            .starting, .thinking, .writing, .toolUse, .waiting,
            .stuck, .idle, .completed, .failed, .interrupted
        ]

        for (i, status) in statuses.enumerated() {
            let session = AgentSession(
                id: "status-test-\(i)",
                project: "Test",
                workingDirectory: "/tmp",
                status: status,
                startedAt: Date()
            )
            try dbPool.write { db in try session.insert(db) }
        }

        let count = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_sessions")
        }
        XCTAssertEqual(count, statuses.count)
    }

    // MARK: - Computed Properties

    func testFilesChangedArray() {
        let session = AgentSession(
            id: "test",
            project: "Test",
            workingDirectory: "/tmp",
            startedAt: Date(),
            filesChanged: "[\"a.swift\",\"b.swift\",\"c.swift\"]"
        )
        XCTAssertEqual(session.filesChangedArray.count, 3)
        XCTAssertEqual(session.filesChangedArray.first, "a.swift")
    }

    func testContextPercentage() {
        let session = AgentSession(
            id: "test",
            project: "Test",
            workingDirectory: "/tmp",
            startedAt: Date(),
            contextUsed: 150000,
            contextMax: 200000
        )
        XCTAssertEqual(session.contextPercentage, 0.75, accuracy: 0.01)
    }

    func testContextPercentageZeroMax() {
        let session = AgentSession(
            id: "test",
            project: "Test",
            workingDirectory: "/tmp",
            startedAt: Date(),
            contextUsed: 100,
            contextMax: 0
        )
        XCTAssertEqual(session.contextPercentage, 0.0)
    }

    func testTotalTokens() {
        let session = AgentSession(
            id: "test",
            project: "Test",
            workingDirectory: "/tmp",
            startedAt: Date(),
            tokensIn: 3000,
            tokensOut: 1000
        )
        XCTAssertEqual(session.totalTokens, 4000)
    }

    func testIsActive() {
        let active = AgentSession(id: "a", project: "T", workingDirectory: "/t", status: .thinking, startedAt: Date())
        let completed = AgentSession(id: "b", project: "T", workingDirectory: "/t", status: .completed, startedAt: Date())
        let failed = AgentSession(id: "c", project: "T", workingDirectory: "/t", status: .failed, startedAt: Date())

        XCTAssertTrue(active.isActive)
        XCTAssertFalse(completed.isActive)
        XCTAssertFalse(failed.isActive)
    }
}
