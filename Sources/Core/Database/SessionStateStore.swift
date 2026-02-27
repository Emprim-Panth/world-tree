import Foundation
import GRDB

/// Reads session state from the `session_state` table (written by the Python memory system).
/// Provides structured data about active sessions for the Dashboard "Session Intelligence" card.
@MainActor
final class SessionStateStore {
    static let shared = SessionStateStore()

    private var db: DatabaseManager { .shared }

    private init() {}

    // MARK: - Model

    struct SessionState {
        let sessionId: String
        let project: String?
        let goal: String?
        let phase: String?
        let blockers: [String]
        let errorCount: Int
        let lastUpdated: Date

        /// SF Symbol name for the detected phase.
        var phaseIcon: String {
            switch phase {
            case "exploring": return "magnifyingglass"
            case "implementing": return "hammer"
            case "testing": return "checkmark.shield"
            case "debugging": return "ant"
            case "starting": return "play.circle"
            default: return "questionmark.circle"
            }
        }

        /// Human-readable phase label.
        var phaseLabel: String {
            (phase ?? "unknown").capitalized
        }
    }

    // MARK: - Queries

    /// Active session states — updated within the last 2 hours.
    func getActiveStates() -> [SessionState] {
        guard let rows = try? db.read({ db in
            // Guard: session_state table may not exist if Python memory system hasn't run yet
            let hasTable = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='session_state'
                """) ?? false
            guard hasTable else { return [Row]() }

            return try Row.fetchAll(db, sql: """
                SELECT session_id, project, goal, phase, blockers, errors_encountered, updated_at
                FROM session_state
                WHERE updated_at > datetime('now', '-2 hours')
                ORDER BY updated_at DESC
                LIMIT 10
                """)
        }) else { return [] }

        return rows.compactMap { parseRow($0) }
    }

    /// Most recent state for a given project.
    func getLatestState(project: String) -> SessionState? {
        let row: Row? = (try? db.read { db in
            let hasTable = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='session_state'
                """) ?? false
            guard hasTable else { return nil }

            return try Row.fetchOne(db, sql: """
                SELECT session_id, project, goal, phase, blockers, errors_encountered, updated_at
                FROM session_state
                WHERE project = ?
                ORDER BY updated_at DESC
                LIMIT 1
                """, arguments: [project])
        }) ?? nil

        guard let row else { return nil }
        return parseRow(row)
    }

    /// The single most recent session state across all projects.
    func getLatestState() -> SessionState? {
        let row: Row? = (try? db.read { db in
            let hasTable = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='session_state'
                """) ?? false
            guard hasTable else { return nil }

            return try Row.fetchOne(db, sql: """
                SELECT session_id, project, goal, phase, blockers, errors_encountered, updated_at
                FROM session_state
                ORDER BY updated_at DESC
                LIMIT 1
                """)
        }) ?? nil

        guard let row else { return nil }
        return parseRow(row)
    }

    // MARK: - Parsing

    private func parseRow(_ row: Row) -> SessionState? {
        guard let sessionId: String = row["session_id"] else { return nil }

        let project: String? = row["project"]
        let goal: String? = row["goal"]
        let phase: String? = row["phase"]
        let updatedAt: Date = row["updated_at"] ?? Date()

        // Parse JSON arrays
        let blockersJSON: String? = row["blockers"]
        let blockers: [String]
        if let json = blockersJSON,
           let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            blockers = arr
        } else {
            blockers = []
        }

        let errorsJSON: String? = row["errors_encountered"]
        let errorCount: Int
        if let json = errorsJSON,
           let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            errorCount = arr.count
        } else {
            errorCount = 0
        }

        return SessionState(
            sessionId: sessionId,
            project: project,
            goal: goal,
            phase: phase,
            blockers: blockers,
            errorCount: errorCount,
            lastUpdated: updatedAt
        )
    }
}
