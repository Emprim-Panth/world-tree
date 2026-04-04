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

    // MARK: - Crew Registry (DB-driven — seeded by v42 migration)

    func testRegistryLoadsFromDB() {
        let store = StarfleetStore.shared
        store.refresh()
        XCTAssertFalse(store.crewRegistry.isEmpty, "crewRegistry should be populated from crew_registry table")
    }

    func testRegistryContainsFullHierarchy() {
        let store = StarfleetStore.shared
        store.refresh()
        let names = store.crewRegistry.map(\.name)

        // Command tier
        XCTAssertTrue(names.contains("Cortana"), "CTO must be present")
        // Department Head
        XCTAssertTrue(names.contains("Picard"), "Dept Head must be present")
        // Key leads
        for lead in ["Geordi", "Torres", "Data", "Worf", "Spock", "Scotty"] {
            XCTAssertTrue(names.contains(lead), "\(lead) (lead) must be present")
        }
    }

    func testRegistryTierHierarchyIsCorrect() {
        let store = StarfleetStore.shared
        store.refresh()

        let cortana = store.crewRegistry.first { $0.name == "Cortana" }
        XCTAssertEqual(cortana?.tier, 1, "Cortana should be Tier 1")

        let picard = store.crewRegistry.first { $0.name == "Picard" }
        XCTAssertEqual(picard?.tier, 2, "Picard should be Tier 2 (Dept Head)")

        let geordi = store.crewRegistry.first { $0.name == "Geordi" }
        XCTAssertEqual(geordi?.tier, 3, "Geordi should be Tier 3 (Lead)")
    }

    func testRegistryGameDevRolesAssigned() {
        let store = StarfleetStore.shared
        store.refresh()

        let picard = store.crewRegistry.first { $0.name == "Picard" }
        XCTAssertNotNil(picard?.gameDevRole, "Picard should have a game dev role")

        let spock = store.crewRegistry.first { $0.name == "Spock" }
        XCTAssertNotNil(spock?.gameDevRole, "Spock should have a game dev role")

        let composer = store.crewRegistry.first { $0.name == "Composer" }
        XCTAssertEqual(composer?.department, "game-dev", "Composer is game-dev dept")
    }

    func testRegistryIconsResolvable() {
        let store = StarfleetStore.shared
        store.refresh()
        for member in store.crewRegistry {
            XCTAssertFalse(member.icon.isEmpty, "\(member.name) should have an icon")
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

        // All registry members should appear in crewActivity with 0 events
        for member in store.crewRegistry {
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

    func testRefreshIncludesNonRegistryAgents() throws {
        try insertActivity(agent: "CustomAgent", eventType: "start", project: "TestProj")

        let store = StarfleetStore.shared
        store.refresh()

        let custom = store.crewActivity["CustomAgent"]
        XCTAssertNotNil(custom, "Agents with activity but no registry entry should appear")
        XCTAssertEqual(custom?.eventCount, 1)
        XCTAssertEqual(custom?.role, "General",
                       "Unknown agent should get 'General' role")
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
            id: "testagent",
            name: "TestAgent",
            role: "Testing",
            gameDevRole: nil,
            department: "coding",
            tier: 4,
            icon: "testtube.2",
            lastEvent: lastEvent,
            lastProject: nil,
            lastSeen: nil,
            eventCount: 0
        )
    }
}
