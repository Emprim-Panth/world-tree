import XCTest
import GRDB
@testable import WorldTree

// MARK: - BriefingStore Unit Tests

/// Tests for BriefingStore.Alert computed properties, resolveAlert() DB operation,
/// and refresh() with empty directories.
@MainActor
final class BriefingStoreTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "briefing-test-\(UUID().uuidString).sqlite"
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

    // MARK: - Alert Model: severityIcon

    func testSeverityIconCritical() {
        let alert = makeAlert(severity: "critical")
        XCTAssertEqual(alert.severityIcon, "exclamationmark.triangle.fill")
    }

    func testSeverityIconWarning() {
        let alert = makeAlert(severity: "warning")
        XCTAssertEqual(alert.severityIcon, "exclamationmark.circle.fill")
    }

    func testSeverityIconInfo() {
        let alert = makeAlert(severity: "info")
        XCTAssertEqual(alert.severityIcon, "info.circle.fill")
    }

    func testSeverityIconUnknown() {
        let alert = makeAlert(severity: "other")
        XCTAssertEqual(alert.severityIcon, "info.circle.fill",
                       "Unknown severity should default to info icon")
    }

    // MARK: - Alert Model: severityColor

    func testSeverityColorCritical() {
        let alert = makeAlert(severity: "critical")
        XCTAssertEqual(alert.severityColor, "red")
    }

    func testSeverityColorWarning() {
        let alert = makeAlert(severity: "warning")
        XCTAssertEqual(alert.severityColor, "orange")
    }

    func testSeverityColorInfo() {
        let alert = makeAlert(severity: "info")
        XCTAssertEqual(alert.severityColor, "blue")
    }

    func testSeverityColorUnknown() {
        let alert = makeAlert(severity: "other")
        XCTAssertEqual(alert.severityColor, "blue",
                       "Unknown severity should default to blue")
    }

    // MARK: - resolveAlert()

    func testResolveAlertSetsResolvedFlag() throws {
        let alertId = "alert-\(UUID().uuidString)"
        try insertAlert(id: alertId, severity: "warning", message: "Test alert")

        // Verify alert exists and is unresolved
        let beforeResolved = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT resolved FROM cortana_alerts WHERE id = ?", arguments: [alertId])
        }
        XCTAssertEqual(beforeResolved, 0, "Alert should start unresolved")

        // Resolve it
        let store = BriefingStore.shared
        store.resolveAlert(id: alertId)

        // Verify resolved=1 in DB
        let afterResolved = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT resolved FROM cortana_alerts WHERE id = ?", arguments: [alertId])
        }
        XCTAssertEqual(afterResolved, 1, "Alert should be resolved after resolveAlert()")

        // Verify resolved_at is set
        let resolvedAt = try dbPool.read { db in
            try String?.fetchOne(db, sql: "SELECT resolved_at FROM cortana_alerts WHERE id = ?", arguments: [alertId])
        }
        XCTAssertNotNil(resolvedAt, "resolved_at should be set")
    }

    func testResolveAlertRefreshesActiveAlerts() throws {
        let alertId = "alert-refresh-\(UUID().uuidString)"
        try insertAlert(id: alertId, severity: "critical", message: "Will be resolved")

        let store = BriefingStore.shared
        store.refresh()

        // Alert should appear in activeAlerts
        XCTAssertTrue(store.activeAlerts.contains(where: { $0.id == alertId }),
                       "Alert should be in activeAlerts before resolving")

        // Resolve it
        store.resolveAlert(id: alertId)

        // Alert should be removed from activeAlerts
        XCTAssertFalse(store.activeAlerts.contains(where: { $0.id == alertId }),
                        "Resolved alert should not be in activeAlerts")
    }

    func testResolveNonexistentAlertDoesNotCrash() {
        let store = BriefingStore.shared
        store.resolveAlert(id: "nonexistent-alert-id")
        // Should not crash or throw
    }

    // MARK: - refresh() with empty directories

    func testRefreshWithEmptyDirectoriesDoesNotCrash() {
        // BriefingStore reads from ~/.cortana/briefings/ and cortana_alerts table.
        // With a test DB (no alerts) and possibly missing briefings dir, refresh should not crash.
        let store = BriefingStore.shared
        store.refresh()
        // No assertion needed — verifying it doesn't crash
    }

    func testRefreshLoadsAlertsFromDB() throws {
        try insertAlert(id: "alert-a", severity: "critical", message: "Critical issue")
        try insertAlert(id: "alert-b", severity: "warning", message: "Warning issue")
        try insertAlert(id: "alert-c", severity: "info", message: "Info note")

        let store = BriefingStore.shared
        store.refresh()

        XCTAssertEqual(store.activeAlerts.count, 3)
        XCTAssertEqual(store.alertCounts.critical, 1)
        XCTAssertEqual(store.alertCounts.warning, 1)
        XCTAssertEqual(store.alertCounts.info, 1)
    }

    func testRefreshOrdersCriticalFirst() throws {
        try insertAlert(id: "alert-info", severity: "info", message: "Low priority")
        try insertAlert(id: "alert-crit", severity: "critical", message: "High priority")

        let store = BriefingStore.shared
        store.refresh()

        guard store.activeAlerts.count >= 2 else {
            XCTFail("Expected at least 2 alerts"); return
        }
        XCTAssertEqual(store.activeAlerts.first?.severity, "critical",
                       "Critical alerts should be ordered first")
    }

    func testRefreshExcludesResolvedAlerts() throws {
        try insertAlert(id: "alert-resolved", severity: "warning", message: "Already resolved")
        try dbPool.write { db in
            try db.execute(sql: "UPDATE cortana_alerts SET resolved = 1 WHERE id = 'alert-resolved'")
        }

        let store = BriefingStore.shared
        store.refresh()

        XCTAssertFalse(store.activeAlerts.contains(where: { $0.id == "alert-resolved" }),
                        "Resolved alerts should not appear in activeAlerts")
    }

    // MARK: - Helpers

    private func makeAlert(severity: String) -> BriefingStore.Alert {
        BriefingStore.Alert(
            id: UUID().uuidString,
            type: "test",
            project: "TestProject",
            message: "Test message",
            severity: severity,
            source: "unit-test",
            createdAt: Date()
        )
    }

    private func insertAlert(id: String, severity: String, message: String) throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO cortana_alerts (id, type, project, message, severity, source, resolved, created_at)
                VALUES (?, 'test', 'TestProject', ?, ?, 'unit-test', 0, datetime('now'))
            """, arguments: [id, message, severity])
        }
    }
}
