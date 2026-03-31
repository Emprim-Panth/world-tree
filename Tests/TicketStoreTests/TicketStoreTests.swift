import XCTest
import GRDB
@testable import WorldTree

// MARK: - TicketStore Unit Tests

/// Tests for TicketStatus enum, Ticket computed properties, and TicketStore
/// database operations (refresh, completedTickets, updateStatus).
@MainActor
final class TicketStoreTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "ticket-test-\(UUID().uuidString).sqlite"
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

    // MARK: - TicketStatus Enum

    func testTicketStatusRawValues() {
        XCTAssertEqual(TicketStatus.pending.rawValue, "pending")
        XCTAssertEqual(TicketStatus.inProgress.rawValue, "in_progress")
        XCTAssertEqual(TicketStatus.review.rawValue, "review")
        XCTAssertEqual(TicketStatus.blocked.rawValue, "blocked")
        XCTAssertEqual(TicketStatus.done.rawValue, "done")
        XCTAssertEqual(TicketStatus.cancelled.rawValue, "cancelled")
        XCTAssertEqual(TicketStatus.unknown.rawValue, "unknown")
    }

    func testTicketStatusInitFromRawValue() {
        XCTAssertEqual(TicketStatus(rawValue: "pending"), .pending)
        XCTAssertEqual(TicketStatus(rawValue: "in_progress"), .inProgress)
        XCTAssertEqual(TicketStatus(rawValue: "done"), .done)
        XCTAssertNil(TicketStatus(rawValue: "bogus"))
    }

    func testTicketStatusUnknownHandling() {
        // Codable decoder should map unrecognized strings to .unknown
        let json = #""not_a_real_status""#
        let data = Data(json.utf8)
        let decoded = try? JSONDecoder().decode(TicketStatus.self, from: data)
        XCTAssertEqual(decoded, .unknown, "Unrecognized status should decode as .unknown")
    }

    func testTicketStatusCodableRoundTrip() {
        for status in [TicketStatus.pending, .inProgress, .review, .blocked, .done, .cancelled, .unknown] {
            let encoded = try? JSONEncoder().encode(status)
            XCTAssertNotNil(encoded, "Encoding \(status) should succeed")
            let decoded = try? JSONDecoder().decode(TicketStatus.self, from: encoded!)
            XCTAssertEqual(decoded, status, "Round-trip for \(status) should preserve value")
        }
    }

    // MARK: - Ticket Computed Properties

    func testIsOpen() {
        XCTAssertTrue(makeTicket(status: .pending).isOpen)
        XCTAssertTrue(makeTicket(status: .inProgress).isOpen)
        XCTAssertTrue(makeTicket(status: .review).isOpen)
        XCTAssertTrue(makeTicket(status: .blocked).isOpen)
        XCTAssertTrue(makeTicket(status: .unknown).isOpen)
        XCTAssertFalse(makeTicket(status: .done).isOpen)
        XCTAssertFalse(makeTicket(status: .cancelled).isOpen)
    }

    func testIsBlocked() {
        XCTAssertTrue(makeTicket(status: .blocked).isBlocked)
        XCTAssertFalse(makeTicket(status: .pending).isBlocked)
        XCTAssertFalse(makeTicket(status: .done).isBlocked)
    }

    func testPriorityOrder() {
        XCTAssertEqual(makeTicket(priority: "critical").priorityOrder, 0)
        XCTAssertEqual(makeTicket(priority: "high").priorityOrder, 1)
        XCTAssertEqual(makeTicket(priority: "medium").priorityOrder, 2)
        XCTAssertEqual(makeTicket(priority: "low").priorityOrder, 3)
        XCTAssertEqual(makeTicket(priority: "unknown").priorityOrder, 4)
    }

    func testStatusIcon() {
        XCTAssertEqual(makeTicket(status: .done).statusIcon, "checkmark.circle.fill")
        XCTAssertEqual(makeTicket(status: .inProgress).statusIcon, "play.circle.fill")
        XCTAssertEqual(makeTicket(status: .blocked).statusIcon, "exclamationmark.triangle.fill")
        XCTAssertEqual(makeTicket(status: .review).statusIcon, "eye.circle.fill")
        XCTAssertEqual(makeTicket(status: .cancelled).statusIcon, "xmark.circle.fill")
        XCTAssertEqual(makeTicket(status: .pending).statusIcon, "circle")
        XCTAssertEqual(makeTicket(status: .unknown).statusIcon, "circle")
    }

    func testCriteriaList() {
        let criteria = #"["Pass all tests","Deploy to staging"]"#
        let ticket = makeTicket(acceptanceCriteria: criteria)
        XCTAssertEqual(ticket.criteriaList, ["Pass all tests", "Deploy to staging"])
    }

    func testCriteriaListNil() {
        let ticket = makeTicket(acceptanceCriteria: nil)
        XCTAssertEqual(ticket.criteriaList, [])
    }

    func testCriteriaListMalformed() {
        let ticket = makeTicket(acceptanceCriteria: "not json")
        XCTAssertEqual(ticket.criteriaList, [])
    }

    func testBlockerList() {
        let blockers = #"["Waiting on API","CI broken"]"#
        let ticket = makeTicket(blockers: blockers)
        XCTAssertEqual(ticket.blockerList, ["Waiting on API", "CI broken"])
    }

    func testBlockerListNil() {
        let ticket = makeTicket(blockers: nil)
        XCTAssertEqual(ticket.blockerList, [])
    }

    func testBlockerListMalformed() {
        let ticket = makeTicket(blockers: "{bad}")
        XCTAssertEqual(ticket.blockerList, [])
    }

    // MARK: - TicketStore.refresh()

    func testRefreshGroupsByProject() throws {
        try insertTicket(id: "TASK-001", project: "Alpha", status: "pending", priority: "high")
        try insertTicket(id: "TASK-002", project: "Alpha", status: "in_progress", priority: "medium")
        try insertTicket(id: "TASK-003", project: "Beta", status: "review", priority: "low")
        try insertTicket(id: "TASK-004", project: "Beta", status: "done", priority: "high")

        let store = TicketStore.shared
        store.refresh()

        XCTAssertEqual(store.tickets.keys.sorted(), ["Alpha", "Beta"],
                       "Should group by project, excluding done tickets")
        XCTAssertEqual(store.tickets["Alpha"]?.count, 2)
        XCTAssertEqual(store.tickets["Beta"]?.count, 1, "Done ticket should be excluded")
    }

    func testRefreshExcludesDoneAndCancelled() throws {
        try insertTicket(id: "TASK-010", project: "Proj", status: "done", priority: "medium")
        try insertTicket(id: "TASK-011", project: "Proj", status: "cancelled", priority: "medium")
        try insertTicket(id: "TASK-012", project: "Proj", status: "pending", priority: "medium")

        let store = TicketStore.shared
        store.refresh()

        XCTAssertEqual(store.tickets["Proj"]?.count, 1)
        XCTAssertEqual(store.tickets["Proj"]?.first?.id, "TASK-012")
    }

    func testRefreshEmptyDatabase() {
        let store = TicketStore.shared
        store.refresh()
        XCTAssertTrue(store.tickets.isEmpty, "No tickets should produce empty dictionary")
    }

    // MARK: - TicketStore.completedTickets(for:)

    func testCompletedTicketsReturnsDoneAndCancelled() throws {
        try insertTicket(id: "TASK-020", project: "Ship", status: "done", priority: "high")
        try insertTicket(id: "TASK-021", project: "Ship", status: "cancelled", priority: "low")
        try insertTicket(id: "TASK-022", project: "Ship", status: "pending", priority: "medium")
        try insertTicket(id: "TASK-023", project: "Other", status: "done", priority: "medium")

        let store = TicketStore.shared
        let completed = store.completedTickets(for: "Ship")

        XCTAssertEqual(completed.count, 2, "Should return done + cancelled for the project")
        let ids = Set(completed.map(\.id))
        XCTAssertTrue(ids.contains("TASK-020"))
        XCTAssertTrue(ids.contains("TASK-021"))
        XCTAssertFalse(ids.contains("TASK-023"), "Should not include other project's tickets")
    }

    func testCompletedTicketsEmptyWhenNone() throws {
        try insertTicket(id: "TASK-030", project: "Fresh", status: "pending", priority: "medium")

        let store = TicketStore.shared
        let completed = store.completedTickets(for: "Fresh")
        XCTAssertTrue(completed.isEmpty)
    }

    // MARK: - TicketStore.updateStatus()

    func testUpdateStatusChangesDBAndRefreshes() throws {
        try insertTicket(id: "TASK-040", project: "Mutate", status: "pending", priority: "high")

        let store = TicketStore.shared
        store.refresh()

        // Verify initial state
        XCTAssertEqual(store.tickets["Mutate"]?.first?.status, .pending)

        // Build a ticket matching the DB row (no filePath so it won't try to write a file)
        let ticket = makeTicket(id: "TASK-040", project: "Mutate", status: .pending, priority: "high")
        store.updateStatus(ticket: ticket, newStatus: .inProgress)

        // Verify DB was updated
        let dbStatus = try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM canvas_tickets WHERE id = ?", arguments: ["TASK-040"])
        }
        XCTAssertEqual(dbStatus, "in_progress")

        // Verify the store refreshed
        XCTAssertEqual(store.tickets["Mutate"]?.first?.status, .inProgress)
    }

    func testUpdateStatusToDoneRemovesFromOpenTickets() throws {
        try insertTicket(id: "TASK-050", project: "Close", status: "in_progress", priority: "medium")

        let store = TicketStore.shared
        store.refresh()
        XCTAssertEqual(store.tickets["Close"]?.count, 1)

        let ticket = makeTicket(id: "TASK-050", project: "Close", status: .inProgress, priority: "medium")
        store.updateStatus(ticket: ticket, newStatus: .done)

        // After marking done, refresh should exclude it from open tickets
        XCTAssertNil(store.tickets["Close"], "Done ticket should not appear in open tickets")

        // But it should appear in completed
        let completed = store.completedTickets(for: "Close")
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.id, "TASK-050")
    }

    // MARK: - Helpers

    private func insertTicket(id: String, project: String, status: String, priority: String) throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO canvas_tickets (id, project, title, status, priority)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [id, project, "\(id) title", status, priority])
        }
    }

    private func makeTicket(
        id: String = "TASK-999",
        project: String = "TestProject",
        status: TicketStatus = .pending,
        priority: String = "medium",
        acceptanceCriteria: String? = nil,
        blockers: String? = nil
    ) -> Ticket {
        Ticket(
            id: id,
            project: project,
            title: "\(id) title",
            description: nil,
            status: status,
            priority: priority,
            assignee: nil,
            sprint: nil,
            filePath: nil,
            acceptanceCriteria: acceptanceCriteria,
            blockers: blockers,
            createdAt: nil,
            updatedAt: nil,
            lastScanned: nil
        )
    }
}
