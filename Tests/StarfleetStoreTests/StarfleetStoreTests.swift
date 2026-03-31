import XCTest
import GRDB
@testable import WorldTree

// MARK: - StarfleetStore Unit Tests

/// Tests for StarfleetStore roster, crew activity refresh, and CrewMember computed properties.
@MainActor
final class StarfleetStoreTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "starfleet-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)
        try MigrationManager.migrate(dbPool)
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

    // MARK: - Roster

    func testRosterHasExpectedCount() {
        XCTAssertEqual(StarfleetStore.roster.count, 12, "Roster should have 12 agents")
    }

    func testRosterContainsAllExpectedNames() {
        let names = StarfleetStore.roster.map(\.name)
        let expected = ["Cortana", "Geordi", "Torres", "Data", "Worf", "Spock",
                        "Scotty", "Friday", "Chief", "Keyes", "Roland", "Halsey"]
        for name in expected {
            XCTAssertTrue(names.contains(name), "Roster should contain \(name)")
        }
    }

    func testRosterEntriesHaveSpecializations() {
        for member in StarfleetStore.roster {
            XCTAssertFalse(member.specialization.isEmpty,
                           "\(member.name) should have a specialization")
        }
    }

    func testRosterEntriesHaveIcons() {
        for member in StarfleetStore.roster {
            XCTAssertFalse(member.icon.isEmpty,
                           "\(member.name) should have an icon")
        }
    }

    // MARK: - CrewMember.isActive

    func testIsActiveForStartEvent() {
        let member = makeCrewMember(lastEvent: "start")
        XCTAssertTrue(member.isActive, "'start' event should be active")
    }

    func testIsActiveForDispatchEvent() {
        let member = makeCrewMember(lastEvent: "dispatch")
        XCTAssertTrue(member.isActive, "'dispatch' event should be active")
    }

    func testIsNotActiveForStopEvent() {
        let member = makeCrewMember(lastEvent: "stop")
        XCTAssertFalse(member.isActive, "'stop' event should not be active")
    }

    func testIsNotActiveForCompleteEvent() {
        let member = makeCrewMember(lastEvent: "complete")
        XCTAssertFalse(member.isActive, "'complete' event should not be active")
    }

    func testIsNotActiveForNilEvent() {
        let member = makeCrewMember(lastEvent: nil)
        XCTAssertFalse(member.isActive, "nil event should not be active")
    }

    func testIsNotActiveForErrorEvent() {
        let member = makeCrewMember(lastEvent: "error")
        XCTAssertFalse(member.isActive, "'error' event should not be active")
    }

    func testIsNotActiveForHeartbeatEvent() {
        let member = makeCrewMember(lastEvent: "heartbeat")
        XCTAssertFalse(member.isActive, "'heartbeat' event should not be active")
    }

    // MARK: - Refresh with Empty Activity Table

    func testRefreshWithEmptyActivityTable() {
        let store = StarfleetStore.shared
        store.refresh()

        // All roster members should appear with 0 events
        XCTAssertEqual(store.crewActivity.count, StarfleetStore.roster.count,
                       "All roster members should appear even with no activity")

        for member in StarfleetStore.roster {
            let crew = store.crewActivity[member.name]
            XCTAssertNotNil(crew, "\(member.name) should be in crewActivity")
            XCTAssertEqual(crew?.eventCount, 0, "\(member.name) should have 0 events")
            XCTAssertNil(crew?.lastEvent, "\(member.name) should have nil lastEvent")
            XCTAssertNil(crew?.lastProject, "\(member.name) should have nil lastProject")
        }
    }

    // MARK: - Refresh with Activity Data

    func testRefreshWithActivityData() throws {
        try insertActivity(agent: "Cortana", eventType: "start", project: "WorldTree")
        try insertActivity(agent: "Cortana", eventType: "complete", project: "WorldTree")
        try insertActivity(agent: "Geordi", eventType: "dispatch", project: "BIMManager")

        let store = StarfleetStore.shared
        store.refresh()

        let cortana = store.crewActivity["Cortana"]
        XCTAssertNotNil(cortana)
        XCTAssertEqual(cortana?.eventCount, 2, "Cortana should have 2 events")
        XCTAssertEqual(cortana?.lastEvent, "complete", "Last event should be 'complete'")
        XCTAssertEqual(cortana?.lastProject, "WorldTree")

        let geordi = store.crewActivity["Geordi"]
        XCTAssertNotNil(geordi)
        XCTAssertEqual(geordi?.eventCount, 1)
        XCTAssertEqual(geordi?.lastEvent, "dispatch")
        XCTAssertEqual(geordi?.lastProject, "BIMManager")
    }

    func testRefreshIncludesNonRosterAgents() throws {
        try insertActivity(agent: "CustomAgent", eventType: "start", project: "TestProj")

        let store = StarfleetStore.shared
        store.refresh()

        let custom = store.crewActivity["CustomAgent"]
        XCTAssertNotNil(custom, "Non-roster agents with activity should appear")
        XCTAssertEqual(custom?.eventCount, 1)
        XCTAssertEqual(custom?.specialization, "General",
                       "Non-roster agent should get 'General' specialization")
    }

    // MARK: - Recent Events

    func testRecentEventsLoaded() throws {
        try insertActivity(agent: "Worf", eventType: "start", project: "Security")
        try insertActivity(agent: "Spock", eventType: "dispatch", project: "Strategy")

        let store = StarfleetStore.shared
        store.refresh()

        XCTAssertEqual(store.recentEvents.count, 2)
        // Recent events are ordered DESC by created_at
        // Both inserted near-simultaneously, so just verify both agents present
        let agents = Set(store.recentEvents.map(\.agentName))
        XCTAssertTrue(agents.contains("Worf"))
        XCTAssertTrue(agents.contains("Spock"))
    }

    func testRecentEventsEmptyWhenNoActivity() {
        let store = StarfleetStore.shared
        store.refresh()
        XCTAssertTrue(store.recentEvents.isEmpty)
    }

    // MARK: - Helpers

    private func insertActivity(agent: String, eventType: String, project: String?) throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO starfleet_activity (agent_name, event_type, project, created_at)
                VALUES (?, ?, ?, datetime('now'))
            """, arguments: [agent, eventType, project])
        }
    }

    private func makeCrewMember(lastEvent: String?) -> StarfleetStore.CrewMember {
        StarfleetStore.CrewMember(
            id: "TestAgent",
            name: "TestAgent",
            specialization: "Testing",
            icon: "testtube.2",
            lastEvent: lastEvent,
            lastProject: nil,
            lastSeen: nil,
            eventCount: 0
        )
    }
}
