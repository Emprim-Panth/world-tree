import XCTest
import GRDB
@testable import WorldTree

// MARK: - PenAssetStoreTests

@MainActor
final class PenAssetStoreTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!
    private var store: PenAssetStore!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "pen-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)
        try MigrationManager.migrate(dbPool)
        DatabaseManager.shared.setDatabasePoolForTesting(dbPool)
        store = PenAssetStore()
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
        store = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private var samplePenURL: URL {
        // Locate fixture relative to this source file
        let here = URL(fileURLWithPath: #file)
        return here
            .deletingLastPathComponent()  // PenAssetStoreTests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("Fixtures/sample.pen")
    }

    // MARK: - 1. Frame count

    func testImportCountsFramesCorrectly() async throws {
        try await store.importFile(at: samplePenURL, project: "TestProject")

        let assetCount = try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT frame_count FROM pen_assets LIMIT 1") ?? 0
        }
        XCTAssertEqual(assetCount, 3, "fixture has 3 top-level frames")

        let nodeCount = try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT node_count FROM pen_assets LIMIT 1") ?? 0
        }
        XCTAssertGreaterThanOrEqual(nodeCount, 3, "total node count must include children")
    }

    // MARK: - 2. Annotation resolves to ticket

    func testFrameLinkResolvesTicketAnnotation() async throws {
        // Seed a matching ticket
        let now = ISO8601DateFormatter().string(from: Date())
        let ticket = Ticket(
            id: "TASK-001",
            project: "TestProject",
            title: "Dashboard frame",
            description: nil,
            status: "pending",
            priority: "high",
            assignee: nil,
            sprint: nil,
            filePath: nil,
            acceptanceCriteria: nil,
            blockers: nil,
            createdAt: now,
            updatedAt: now,
            lastScanned: now
        )
        try await dbPool.write { db in try ticket.insert(db) }

        try await store.importFile(at: samplePenURL, project: "TestProject")

        let resolvedTicketId = try await dbPool.read { db in
            try String.fetchOne(db, sql: """
                SELECT ticket_id FROM pen_frame_links
                WHERE annotation = 'TASK-001'
                LIMIT 1
                """)
        }
        XCTAssertEqual(resolvedTicketId, "TASK-001", "annotation TASK-001 must resolve to ticket")
    }

    // MARK: - 3. Null ticket when no match

    func testFrameLinkNullTicketWhenNoMatch() async throws {
        // No ticket seeded — TASK-999 exists in the fixture but not in canvas_tickets
        try await store.importFile(at: samplePenURL, project: "TestProject")

        let (linkExists, ticketId) = try await dbPool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT id, ticket_id FROM pen_frame_links
                WHERE annotation = 'TASK-999'
                LIMIT 1
                """)
            return (row != nil, row?["ticket_id"] as String?)
        }
        XCTAssertTrue(linkExists, "link row must exist for TASK-999 annotation")
        XCTAssertNil(ticketId, "ticket_id must be NULL when no matching ticket found")
    }

    // MARK: - 4. Delete cascades to frame links

    func testDeleteCascadesToFrameLinks() async throws {
        try await store.importFile(at: samplePenURL, project: "TestProject")

        // Confirm links exist
        let linksBefore = try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pen_frame_links") ?? 0
        }
        XCTAssertGreaterThan(linksBefore, 0, "links must exist after import")

        // Get the asset id
        let assetId = try await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM pen_assets LIMIT 1")
        }
        XCTAssertNotNil(assetId)

        // Delete asset — cascade should remove links
        try await store.deleteAsset(id: assetId!, project: "TestProject")

        let linksAfter = try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pen_frame_links") ?? 0
        }
        XCTAssertEqual(linksAfter, 0, "frame links must cascade-delete with asset")
    }

    // MARK: - 5. Migration idempotency

    func testMigrationV22IsIdempotent() async throws {
        // Migration was already run in setUp(). Run again — must not throw.
        XCTAssertNoThrow(try MigrationManager.migrate(dbPool))

        // Tables must still exist
        let tables = try await dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table'
                AND name IN ('pen_assets','pen_frame_links')
                ORDER BY name
                """)
        }
        XCTAssertEqual(tables.sorted(), ["pen_assets", "pen_frame_links"])
    }
}
