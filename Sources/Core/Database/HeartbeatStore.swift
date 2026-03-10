import Foundation
import GRDB

// MARK: - Heartbeat Signal Model

struct HeartbeatSignal: Identifiable {
    let id: String
    let category: String
    let content: String
    let project: String?
    let actionTaken: String?
    let timestamp: Date?
}

// MARK: - Heartbeat Run Model

struct HeartbeatRun {
    let id: String
    let intensity: String
    let startedAt: Date?
    let completedAt: Date?
    let signalsFound: Int
    let dispatchesMade: Int
    let summary: String?
}

// MARK: - Heartbeat Store

/// Reads heartbeat data from conversations.db (same DB World Tree already connects to).
/// All data is written by cortana-cli heartbeat — World Tree only reads.
@MainActor
final class HeartbeatStore: ObservableObject {
    static let shared = HeartbeatStore()

    @Published private(set) var lastHeartbeat: Date?
    @Published private(set) var lastIntensity: String = "unknown"
    @Published private(set) var lastSignalCount: Int = 0
    @Published private(set) var lastDispatchCount: Int = 0
    @Published private(set) var activeDispatches: Int = 0
    @Published private(set) var recentSignals: [HeartbeatSignal] = []

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()

    private init() {}

    // MARK: - Refresh

    /// Pull latest heartbeat data from conversations.db.
    func refresh() {
        do {
            // Last heartbeat run
            if let row = try DatabaseManager.shared.read({ db in
                try Row.fetchOne(db, sql: """
                    SELECT id, intensity, started_at, completed_at, signals_found, dispatches_made, summary
                    FROM heartbeat_runs
                    ORDER BY started_at DESC LIMIT 1
                    """)
            }) {
                let startedStr: String? = row["started_at"]
                lastHeartbeat = startedStr.flatMap { Self.dateFormatter.date(from: $0) }
                lastIntensity = row["intensity"] ?? "unknown"
                lastSignalCount = row["signals_found"] ?? 0
                lastDispatchCount = row["dispatches_made"] ?? 0
            }

            // Active canvas dispatches (running or queued)
            let count = try DatabaseManager.shared.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT count(*) FROM canvas_dispatches
                    WHERE status IN ('queued', 'running')
                    """) ?? 0
            }
            activeDispatches = count

            // Recent governance signals (last 24h)
            let signalRows = try DatabaseManager.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, category, content, project, action_taken, created_at
                    FROM governance_journal
                    ORDER BY created_at DESC
                    LIMIT 20
                    """)
            }
            recentSignals = signalRows.map { row in
                let dateStr: String? = row["created_at"]
                return HeartbeatSignal(
                    id: row["id"] ?? UUID().uuidString,
                    category: row["category"] ?? "unknown",
                    content: row["content"] ?? "",
                    project: row["project"],
                    actionTaken: row["action_taken"],
                    timestamp: dateStr.flatMap { Self.dateFormatter.date(from: $0) }
                )
            }
        } catch {
            wtLog("[HeartbeatStore] Error refreshing: \(error)")
        }
    }
}
