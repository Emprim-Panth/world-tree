import Foundation
import GRDB

/// Persists security gate approvals in SQLite via DatabaseManager.
/// Keyed by ToolGuard assessment reason string — same pattern = same key.
///
/// Previously backed by UserDefaults. Migration v18 moves existing approvals
/// into the canvas_security_approvals table and cleans up UserDefaults.
@MainActor
final class PermissionStore {
    static let shared = PermissionStore()

    private init() {}

    func isApproved(reason: String) -> Bool {
        guard let dbPool = DatabaseManager.shared.dbPool else { return false }
        return (try? dbPool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM canvas_security_approvals WHERE pattern = ?)",
                arguments: [reason]
            )
        }) ?? false
    }

    func approve(reason: String) {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }
        try? dbPool.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO canvas_security_approvals (pattern, approved_at) VALUES (?, CURRENT_TIMESTAMP)",
                arguments: [reason]
            )
        }
    }

    func revoke(reason: String) {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }
        try? dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM canvas_security_approvals WHERE pattern = ?",
                arguments: [reason]
            )
        }
    }

    func allApproved() -> [String] {
        guard let dbPool = DatabaseManager.shared.dbPool else { return [] }
        return (try? dbPool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT pattern FROM canvas_security_approvals ORDER BY approved_at"
            )
        }) ?? []
    }
}
