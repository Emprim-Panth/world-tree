import XCTest
import GRDB
@testable import WorldTree

// MARK: - PermissionStore Tests

/// Tests for PermissionStore SQL logic — approval, revocation, listing, deduplication.
/// Uses a temporary DatabasePool with full migrations, exercising the same queries
/// PermissionStore uses against canvas_security_approvals (created in migration v18).
@MainActor
final class PermissionStoreTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "permission-store-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)
        try MigrationManager.migrate(dbPool)
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

    // MARK: - Helpers

    /// Mirrors PermissionStore.approve() — INSERT OR IGNORE into canvas_security_approvals.
    private func approve(reason: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO canvas_security_approvals (pattern, approved_at) VALUES (?, CURRENT_TIMESTAMP)",
                arguments: [reason]
            )
        }
    }

    /// Mirrors PermissionStore.revoke() — DELETE from canvas_security_approvals.
    private func revoke(reason: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM canvas_security_approvals WHERE pattern = ?",
                arguments: [reason]
            )
        }
    }

    /// Mirrors PermissionStore.isApproved() — SELECT EXISTS check.
    private func isApproved(reason: String) -> Bool {
        (try? dbPool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM canvas_security_approvals WHERE pattern = ?)",
                arguments: [reason]
            )
        }) ?? false
    }

    /// Mirrors PermissionStore.allApproved() — SELECT all patterns ordered by approved_at.
    private func allApproved() -> [String] {
        (try? dbPool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT pattern FROM canvas_security_approvals ORDER BY approved_at"
            )
        }) ?? []
    }

    // MARK: - 1. testApproveAndCheck

    func testApproveAndCheck() throws {
        let pattern = "bash:rm -rf /tmp/*"

        // Before approval
        XCTAssertFalse(isApproved(reason: pattern), "Pattern should not be approved before calling approve")

        // Approve
        try approve(reason: pattern)

        // After approval
        XCTAssertTrue(isApproved(reason: pattern), "Pattern should be approved after calling approve")
    }

    // MARK: - 2. testRevokePattern

    func testRevokePattern() throws {
        let pattern = "tool:file_write:/etc/hosts"

        // Approve then verify
        try approve(reason: pattern)
        XCTAssertTrue(isApproved(reason: pattern), "Pattern should be approved")

        // Revoke
        try revoke(reason: pattern)

        // After revocation
        XCTAssertFalse(isApproved(reason: pattern), "Pattern should not be approved after revocation")
    }

    // MARK: - 3. testAllApproved

    func testAllApproved() throws {
        // Start empty
        XCTAssertEqual(allApproved(), [], "allApproved should return empty array when no patterns exist")

        // Approve multiple patterns
        try approve(reason: "bash:git push")
        try approve(reason: "bash:cargo build")
        try approve(reason: "tool:file_read")

        let all = allApproved()
        XCTAssertEqual(all.count, 3, "Should have exactly 3 approved patterns")
        XCTAssertTrue(all.contains("bash:git push"), "Should contain git push pattern")
        XCTAssertTrue(all.contains("bash:cargo build"), "Should contain cargo build pattern")
        XCTAssertTrue(all.contains("tool:file_read"), "Should contain file_read pattern")
    }

    // MARK: - 4. testDuplicateApproval

    func testDuplicateApproval() throws {
        let pattern = "bash:xcodebuild -scheme WorldTree"

        // Approve the same pattern twice
        try approve(reason: pattern)
        try approve(reason: pattern)

        // Should still be approved (no error thrown)
        XCTAssertTrue(isApproved(reason: pattern), "Pattern should be approved after duplicate approval")

        // Count: should be exactly 1 row, not 2 (INSERT OR IGNORE)
        let count = try dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM canvas_security_approvals WHERE pattern = ?",
                arguments: [pattern]
            )
        }
        XCTAssertEqual(count, 1, "Duplicate approval must not create a second row (INSERT OR IGNORE)")
    }

    // MARK: - 5. testEmptyStore

    func testEmptyStore() throws {
        // Fresh database after migration — no approvals exist
        XCTAssertFalse(isApproved(reason: "anything"), "isApproved should return false on empty store")
        XCTAssertFalse(isApproved(reason: ""), "isApproved should return false for empty string")
        XCTAssertEqual(allApproved(), [], "allApproved should return empty array on empty store")
    }

    // MARK: - Additional Edge Cases

    func testRevokeNonExistentPattern() throws {
        // Revoking a pattern that was never approved should not error
        XCTAssertNoThrow(try revoke(reason: "never-approved-pattern"))
        XCTAssertFalse(isApproved(reason: "never-approved-pattern"))
    }

    func testApproveMultipleThenRevokeOne() throws {
        try approve(reason: "pattern-a")
        try approve(reason: "pattern-b")
        try approve(reason: "pattern-c")

        // Revoke only pattern-b
        try revoke(reason: "pattern-b")

        XCTAssertTrue(isApproved(reason: "pattern-a"), "pattern-a should remain approved")
        XCTAssertFalse(isApproved(reason: "pattern-b"), "pattern-b should be revoked")
        XCTAssertTrue(isApproved(reason: "pattern-c"), "pattern-c should remain approved")

        let all = allApproved()
        XCTAssertEqual(all.count, 2, "Should have 2 remaining approved patterns")
        XCTAssertFalse(all.contains("pattern-b"), "Revoked pattern should not appear in allApproved")
    }

    func testSecurityApprovalsTableExists() throws {
        // Verify migration v18 created the table
        let tables = try dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name='canvas_security_approvals'
                """)
        }
        XCTAssertEqual(tables, ["canvas_security_approvals"],
                        "Migration v18 must create canvas_security_approvals table")
    }

    func testPatternWithSpecialCharacters() throws {
        // Patterns may contain special SQL characters — verify they're handled safely
        let specialPatterns = [
            "bash:echo 'hello world'",
            "tool:path with spaces/file.txt",
            "bash:grep -E \"pattern|other\"",
            "tool:file_write:~/Development/World Tree/test.swift"
        ]

        for pattern in specialPatterns {
            try approve(reason: pattern)
            XCTAssertTrue(isApproved(reason: pattern), "Pattern with special chars should be approved: \(pattern)")
        }

        XCTAssertEqual(allApproved().count, specialPatterns.count,
                        "All special-character patterns should be stored")
    }
}
