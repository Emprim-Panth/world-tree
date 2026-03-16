import XCTest
@testable import WorldTree

// MARK: - Session Health Tests

@MainActor
final class SessionHealthTests: XCTestCase {

    // MARK: - Perfect Health

    func testPerfectHealth() {
        let session = AgentSession(
            id: "healthy",
            project: "Test",
            workingDirectory: "/tmp",
            status: .writing,
            startedAt: Date().addingTimeInterval(-600),
            consecutiveErrors: 0,
            tokensIn: 50000,
            tokensOut: 10000,
            contextUsed: 60000,
            contextMax: 200000,
            filesChanged: "[\"a.swift\",\"b.swift\"]"
        )
        let health = SessionHealth.calculate(from: session)
        XCTAssertEqual(health.level, .green)
        XCTAssertGreaterThanOrEqual(health.score, 0.65)
    }

    // MARK: - Worst Case

    func testWorstCase() {
        let session = AgentSession(
            id: "unhealthy",
            project: "Test",
            workingDirectory: "/tmp",
            status: .stuck,
            startedAt: Date().addingTimeInterval(-3600),
            consecutiveErrors: 6,
            tokensIn: 190000,
            tokensOut: 5000,
            contextUsed: 195000,
            contextMax: 200000,
            filesChanged: "[]"
        )
        let health = SessionHealth.calculate(from: session)
        XCTAssertEqual(health.level, .red)
    }

    // MARK: - Static Overrides

    func testStuckOverride() {
        let session = AgentSession(
            id: "stuck",
            project: "Test",
            workingDirectory: "/tmp",
            status: .stuck,
            startedAt: Date(),
            consecutiveErrors: 0,
            contextUsed: 10000,
            contextMax: 200000
        )
        let health = SessionHealth.calculate(from: session)
        XCTAssertEqual(health.level, .red)
    }

    func testHighConsecutiveErrorsOverride() {
        let session = AgentSession(
            id: "errors",
            project: "Test",
            workingDirectory: "/tmp",
            status: .toolUse,
            startedAt: Date(),
            consecutiveErrors: 5,
            contextUsed: 10000,
            contextMax: 200000
        )
        let health = SessionHealth.calculate(from: session)
        XCTAssertEqual(health.level, .red)
    }

    func testContextExhaustionOverride() {
        let session = AgentSession(
            id: "ctx",
            project: "Test",
            workingDirectory: "/tmp",
            status: .thinking,
            startedAt: Date(),
            consecutiveErrors: 0,
            contextUsed: 196000,
            contextMax: 200000
        )
        let health = SessionHealth.calculate(from: session)
        XCTAssertEqual(health.level, .red)
    }

    // MARK: - Yellow Zone

    func testYellowZone() {
        let session = AgentSession(
            id: "yellow",
            project: "Test",
            workingDirectory: "/tmp",
            status: .toolUse,
            startedAt: Date().addingTimeInterval(-600),
            consecutiveErrors: 3,
            tokensIn: 100000,
            tokensOut: 20000,
            contextUsed: 150000,
            contextMax: 200000,
            filesChanged: "[\"a.swift\"]"
        )
        let health = SessionHealth.calculate(from: session)
        XCTAssertEqual(health.level, .yellow)
    }

    // MARK: - Brand New Session

    func testBrandNewSession() {
        let session = AgentSession(
            id: "new",
            project: "Test",
            workingDirectory: "/tmp",
            status: .starting,
            startedAt: Date(),
            tokensIn: 0,
            tokensOut: 0,
            contextUsed: 0,
            contextMax: 200000
        )
        let health = SessionHealth.calculate(from: session)
        XCTAssertEqual(health.level, .green)
    }
}
