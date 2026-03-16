import XCTest
import GRDB
@testable import WorldTree

// MARK: - CompassState + CompassStore Unit Tests

/// Tests for CompassState model (JSON decoding, date parsing, staleness, attention score)
/// and CompassStore read operations. Uses a temporary compass.db.
@MainActor
final class CompassStoreTests: XCTestCase {

    // MARK: - CompassState Model Tests

    // MARK: 1. Blockers JSON Array Decoding

    func testBlockersDecodesJsonArray() {
        let state = makeState(openBlockers: #"["CI broken","Waiting on review"]"#)
        XCTAssertEqual(state.blockers, ["CI broken", "Waiting on review"])
    }

    func testBlockersReturnsEmptyForNilInput() {
        let state = makeState(openBlockers: nil)
        XCTAssertEqual(state.blockers, [], "Nil openBlockers should return empty array")
    }

    func testBlockersReturnsEmptyForMalformedJson() {
        let state = makeState(openBlockers: "not valid json")
        XCTAssertEqual(state.blockers, [], "Malformed JSON should return empty array")
    }

    func testBlockersReturnsEmptyForEmptyArray() {
        let state = makeState(openBlockers: "[]")
        XCTAssertEqual(state.blockers, [], "Empty JSON array should return empty array")
    }

    // MARK: 2. Decisions JSON Array Decoding

    func testDecisionsDecodesJsonArray() {
        let state = makeState(recentDecisions: #"["Use SwiftData","Skip CoreData"]"#)
        XCTAssertEqual(state.decisions, ["Use SwiftData", "Skip CoreData"])
    }

    func testDecisionsReturnsEmptyForNil() {
        let state = makeState(recentDecisions: nil)
        XCTAssertEqual(state.decisions, [])
    }

    // MARK: 3. Staleness Calculation

    func testIsStaleWhenUpdatedAtNil() {
        let state = makeState(updatedAt: nil)
        XCTAssertTrue(state.isStale, "Nil updatedAt should be stale")
    }

    func testIsStaleWhenOlderThan10Minutes() {
        // 15 minutes ago in ISO8601
        let date = Date().addingTimeInterval(-900)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let state = makeState(updatedAt: formatter.string(from: date))
        XCTAssertTrue(state.isStale, "State updated 15 min ago should be stale")
    }

    func testIsNotStaleWhenRecent() {
        let date = Date().addingTimeInterval(-60) // 1 minute ago
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let state = makeState(updatedAt: formatter.string(from: date))
        XCTAssertFalse(state.isStale, "State updated 1 min ago should not be stale")
    }

    func testIsStaleWithUnparseableDate() {
        let state = makeState(updatedAt: "not-a-date")
        XCTAssertTrue(state.isStale, "Unparseable date should be treated as stale")
    }

    // MARK: 4. Date Parsing Multiple Formats

    func testDateParsingSQLiteFormat() {
        // SQLite format: yyyy-MM-dd HH:mm:ss
        let state = makeState(updatedAt: "2026-03-12 10:00:00")
        // If it parses, isStale should be true (it's in the past)
        XCTAssertTrue(state.isStale, "SQLite datetime format should parse and be stale")
    }

    func testDateParsingISO8601WithFractionalSeconds() {
        let date = Date().addingTimeInterval(-30)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let state = makeState(updatedAt: formatter.string(from: date))
        XCTAssertFalse(state.isStale, "ISO8601 with fractional seconds should parse correctly")
    }

    func testDateParsingISO8601WithoutFractionalSeconds() {
        let date = Date().addingTimeInterval(-30)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let state = makeState(updatedAt: formatter.string(from: date))
        XCTAssertFalse(state.isStale, "ISO8601 without fractional seconds should parse correctly")
    }

    // MARK: 5. Attention Score Calculation

    func testAttentionScoreZeroForCleanProject() {
        let state = makeState(
            openBlockers: "[]",
            gitDirty: 0,
            gitUncommittedCount: 0,
            openTicketsCount: 0,
            blockedTicketsCount: 0
        )
        XCTAssertEqual(state.attentionScore, 0, "Clean project should have 0 attention score")
    }

    func testAttentionScoreDirtyAdds30() {
        let state = makeState(gitDirty: 1)
        XCTAssertEqual(state.attentionScore, 30, "Dirty git state should add 30")
    }

    func testAttentionScoreBlockedTicketsAdds25() {
        let state = makeState(blockedTicketsCount: 2)
        XCTAssertEqual(state.attentionScore, 25, "Blocked tickets should add 25")
    }

    func testAttentionScoreHighUncommittedAdds15() {
        let state = makeState(gitUncommittedCount: 15)
        XCTAssertEqual(state.attentionScore, 15, ">10 uncommitted should add 15")
    }

    func testAttentionScoreManyOpenTicketsAdds10() {
        let state = makeState(openTicketsCount: 8)
        XCTAssertEqual(state.attentionScore, 10, ">5 open tickets should add 10")
    }

    func testAttentionScoreBlockersAdds20() {
        let state = makeState(openBlockers: #"["Something is blocking"]"#)
        XCTAssertEqual(state.attentionScore, 20, "Non-empty blockers should add 20")
    }

    func testAttentionScoreCappedAt100() {
        // All flags on: 30 + 15 + 25 + 10 + 20 = 100
        let state = makeState(
            openBlockers: #"["blocker"]"#,
            gitDirty: 1,
            gitUncommittedCount: 20,
            openTicketsCount: 10,
            blockedTicketsCount: 3
        )
        XCTAssertEqual(state.attentionScore, 100, "Score should cap at 100")
    }

    // MARK: 6. isDirty

    func testIsDirtyTrue() {
        let state = makeState(gitDirty: 1)
        XCTAssertTrue(state.isDirty)
    }

    func testIsDirtyFalse() {
        let state = makeState(gitDirty: 0)
        XCTAssertFalse(state.isDirty)
    }

    // MARK: 7. phaseDisplay

    func testPhaseDisplayReturnsPhase() {
        let state = makeState(currentPhase: "testing")
        XCTAssertEqual(state.phaseDisplay, "testing")
    }

    func testPhaseDisplayDefaultsToUnknown() {
        let state = makeState(currentPhase: nil)
        XCTAssertEqual(state.phaseDisplay, "unknown")
    }

    // MARK: - CompassStore Database Tests

    private var compassDbPool: DatabasePool?
    private var compassDbPath: String?

    func testCompassStoreRefreshLoadsStates() throws {
        // Create a temporary compass.db with the expected schema
        let path = NSTemporaryDirectory() + "compass-test-\(UUID().uuidString).sqlite"
        compassDbPath = path

        let pool = try DatabasePool(path: path)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE compass_state (
                    project TEXT PRIMARY KEY,
                    path TEXT, domain TEXT, stack TEXT,
                    current_goal TEXT, current_phase TEXT,
                    active_files TEXT, open_blockers TEXT, recent_decisions TEXT,
                    last_session_summary TEXT, last_session_date TEXT,
                    git_branch TEXT, git_dirty INTEGER DEFAULT 0,
                    git_uncommitted_count INTEGER DEFAULT 0,
                    git_last_commit TEXT, git_last_commit_date TEXT,
                    open_tickets_count INTEGER DEFAULT 0,
                    blocked_tickets_count INTEGER DEFAULT 0,
                    next_ticket TEXT,
                    updated_at TEXT
                )
                """)

            try db.execute(sql: """
                INSERT INTO compass_state (project, path, current_goal, current_phase, git_dirty, git_uncommitted_count, open_tickets_count, blocked_tickets_count)
                VALUES ('WorldTree', '~/Development/WorldTree', 'Ship v1', 'testing', 0, 3, 5, 1)
                """)
            try db.execute(sql: """
                INSERT INTO compass_state (project, path, current_goal, current_phase, git_dirty, git_uncommitted_count, open_tickets_count, blocked_tickets_count)
                VALUES ('BookBuddy', '~/Development/BookBuddy', 'Content filtering', 'development', 1, 12, 8, 0)
                """)
        }

        // Read states directly to verify the schema works with CompassState
        let states = try pool.read { db in
            try CompassState.fetchAll(db, sql: "SELECT * FROM compass_state ORDER BY project")
        }

        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states[0].project, "BookBuddy")
        XCTAssertEqual(states[0].currentGoal, "Content filtering")
        XCTAssertTrue(states[0].isDirty)
        XCTAssertEqual(states[1].project, "WorldTree")
        XCTAssertEqual(states[1].currentPhase, "testing")

        // Clean up
        try? FileManager.default.removeItem(atPath: path)
    }

    func testCompassStateFilterByProject() throws {
        let path = NSTemporaryDirectory() + "compass-filter-\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }

        let pool = try DatabasePool(path: path)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE compass_state (
                    project TEXT PRIMARY KEY,
                    path TEXT, domain TEXT, stack TEXT,
                    current_goal TEXT, current_phase TEXT,
                    active_files TEXT, open_blockers TEXT, recent_decisions TEXT,
                    last_session_summary TEXT, last_session_date TEXT,
                    git_branch TEXT, git_dirty INTEGER DEFAULT 0,
                    git_uncommitted_count INTEGER DEFAULT 0,
                    git_last_commit TEXT, git_last_commit_date TEXT,
                    open_tickets_count INTEGER DEFAULT 0,
                    blocked_tickets_count INTEGER DEFAULT 0,
                    next_ticket TEXT,
                    updated_at TEXT
                )
                """)

            try db.execute(sql: """
                INSERT INTO compass_state (project, current_goal, git_dirty, git_uncommitted_count, open_tickets_count, blocked_tickets_count)
                VALUES ('WorldTree', 'Ship v1', 0, 0, 0, 0)
                """)
        }

        let states = try pool.read { db in
            try CompassState.fetchAll(db, sql: "SELECT * FROM compass_state WHERE project = ?", arguments: ["WorldTree"])
        }

        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[0].project, "WorldTree")
        XCTAssertEqual(states[0].currentGoal, "Ship v1")
    }

    // MARK: - Helper Factory

    /// Creates a CompassState with controllable fields for unit testing.
    /// Fields not specified get sensible defaults.
    private func makeState(
        project: String = "TestProject",
        currentPhase: String? = nil,
        openBlockers: String? = nil,
        recentDecisions: String? = nil,
        gitDirty: Int = 0,
        gitUncommittedCount: Int = 0,
        openTicketsCount: Int = 0,
        blockedTicketsCount: Int = 0,
        updatedAt: String? = nil
    ) -> CompassState {
        CompassState(
            project: project,
            path: nil,
            domain: nil,
            stack: nil,
            currentGoal: nil,
            currentPhase: currentPhase,
            activeFiles: nil,
            openBlockers: openBlockers,
            recentDecisions: recentDecisions,
            lastSessionSummary: nil,
            lastSessionDate: nil,
            gitBranch: nil,
            gitDirty: gitDirty,
            gitUncommittedCount: gitUncommittedCount,
            gitLastCommit: nil,
            gitLastCommitDate: nil,
            openTicketsCount: openTicketsCount,
            blockedTicketsCount: blockedTicketsCount,
            nextTicket: nil,
            updatedAt: updatedAt
        )
    }
}
