import Foundation
import GRDB

// MARK: - Attention Store

/// Reactive store for agent attention events — permission prompts, stuck agents, error loops.
/// Observes `agent_attention_events` via GRDB ValueObservation so the UI updates automatically.
/// All data is written by cortana-core / heartbeat — World Tree only reads + acknowledges.
@MainActor
final class AttentionStore: ObservableObject {
    static let shared = AttentionStore()

    @Published private(set) var unacknowledged: [AttentionEvent] = []
    @Published private(set) var criticalCount: Int = 0
    @Published private(set) var warningCount: Int = 0

    private var observation: AnyDatabaseCancellable?

    private init() {}

    // MARK: - Observation

    /// Start observing unacknowledged attention events. Call once at app launch.
    func startObserving() {
        guard let dbPool = DatabaseManager.shared.dbPool else {
            wtLog("[AttentionStore] No database pool — skipping observation")
            return
        }

        let obs = ValueObservation.trackingConstantRegion { db -> [AttentionEvent] in
            guard try db.tableExists("agent_attention_events") else { return [] }

            // Auto-acknowledge 'completed' events older than 1 hour
            try db.execute(sql: """
                UPDATE agent_attention_events
                SET acknowledged = 1, acknowledged_at = datetime('now')
                WHERE acknowledged = 0
                  AND type = 'completed'
                  AND created_at < datetime('now', '-1 hour')
                """)

            return try AttentionEvent.fetchAll(db, sql: """
                SELECT *
                FROM agent_attention_events
                WHERE acknowledged = 0
                ORDER BY
                    CASE severity
                        WHEN 'critical' THEN 0
                        WHEN 'warning' THEN 1
                        ELSE 2
                    END,
                    created_at DESC
                LIMIT 50
                """)
        }

        observation = obs.start(
            in: dbPool,
            scheduling: .async(onQueue: .main),
            onError: { error in
                Task { @MainActor in
                    wtLog("[AttentionStore] Observation error: \(error)")
                }
            },
            onChange: { [weak self] events in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.unacknowledged = events
                    self.criticalCount = events.filter { $0.severity == .critical }.count
                    self.warningCount = events.filter { $0.severity == .warning }.count
                }
            }
        )
    }

    /// Stop observing. Call on teardown or when the view disappears.
    func stopObserving() {
        observation?.cancel()
        observation = nil
    }

    // MARK: - Actions

    /// Acknowledge a single attention event by ID.
    func acknowledge(_ id: String) {
        do {
            try DatabaseManager.shared.write { db in
                guard try db.tableExists("agent_attention_events") else { return }
                try db.execute(
                    sql: """
                        UPDATE agent_attention_events
                        SET acknowledged = 1, acknowledged_at = datetime('now')
                        WHERE id = ?
                        """,
                    arguments: [id]
                )
            }
        } catch {
            wtLog("[AttentionStore] Error acknowledging event \(id): \(error)")
        }
    }

    /// Acknowledge all unacknowledged events.
    func acknowledgeAll() {
        do {
            try DatabaseManager.shared.write { db in
                guard try db.tableExists("agent_attention_events") else { return }
                try db.execute(sql: """
                    UPDATE agent_attention_events
                    SET acknowledged = 1, acknowledged_at = datetime('now')
                    WHERE acknowledged = 0
                    """)
            }
        } catch {
            wtLog("[AttentionStore] Error acknowledging all events: \(error)")
        }
    }
}
