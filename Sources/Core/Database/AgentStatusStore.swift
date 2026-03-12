import Foundation
import GRDB

// MARK: - Agent Status Store

/// Reactive observation layer for agent sessions.
/// Reads agent_sessions and agent_attention_events from conversations.db.
/// Uses ValueObservation for live updates and a watchdog timer for stuck detection.
@MainActor
final class AgentStatusStore: ObservableObject {
    static let shared = AgentStatusStore()

    @Published private(set) var activeSessions: [AgentSession] = []
    @Published private(set) var recentCompleted: [AgentSession] = []
    @Published private(set) var totalActiveCount: Int = 0

    private var observation: DatabaseCancellable?
    private var watchdogTimer: Timer?

    /// How long a session can be silent before it's considered stuck (5 minutes).
    private static let stuckThresholdSeconds: TimeInterval = 300

    /// Watchdog check interval (30 seconds).
    private static let watchdogInterval: TimeInterval = 30

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()

    private init() {}

    // MARK: - Observation Lifecycle

    /// Begin observing the agent_sessions table for changes.
    /// Safe to call multiple times — restarts observation if already running.
    func startObserving() {
        stopObserving()

        guard let dbPool = DatabaseManager.shared.dbPool else {
            wtLog("[AgentStatusStore] Cannot observe — database not connected")
            return
        }

        // ValueObservation fires on every INSERT/UPDATE to agent_sessions.
        // The fetch runs on GRDB's reader queue; we receive results on MainActor.
        let observation = ValueObservation.tracking { db -> FetchResult in
            guard try db.tableExists("agent_sessions") else {
                return FetchResult(active: [], completed: [])
            }

            let active = try AgentSession.fetchAll(db, sql: """
                SELECT * FROM agent_sessions
                WHERE status NOT IN ('completed', 'failed', 'interrupted')
                ORDER BY last_activity_at DESC
                """)

            let completed = try AgentSession.fetchAll(db, sql: """
                SELECT * FROM agent_sessions
                WHERE status IN ('completed', 'failed')
                ORDER BY completed_at DESC
                LIMIT 20
                """)

            return FetchResult(active: active, completed: completed)
        }

        self.observation = observation.start(
            in: dbPool,
            scheduling: .immediate,
            onError: { error in
                Task { @MainActor in
                    wtLog("[AgentStatusStore] Observation error: \(error)")
                }
            },
            onChange: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activeSessions = result.active
                    self.recentCompleted = result.completed
                    self.totalActiveCount = result.active.count
                }
            }
        )

        // Start watchdog timer for stuck detection
        startWatchdog()
    }

    /// Stop observing and tear down the watchdog timer.
    func stopObserving() {
        observation?.cancel()
        observation = nil
        stopWatchdog()
    }

    // MARK: - Manual Refresh

    /// One-shot async refresh — runs DB reads off MainActor, assigns on main thread.
    func refreshAsync() async {
        do {
            let result = try await Self.fetchAllAsync()
            self.activeSessions = result.active
            self.recentCompleted = result.completed
            self.totalActiveCount = result.active.count
        } catch {
            wtLog("[AgentStatusStore] Error refreshing async: \(error)")
        }
    }

    // MARK: - Watchdog

    /// Periodically checks for sessions that appear active but haven't reported
    /// activity in over 5 minutes. Marks them 'stuck' and inserts an attention event.
    private func startWatchdog() {
        stopWatchdog()
        watchdogTimer = Timer.scheduledTimer(
            withTimeInterval: Self.watchdogInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runWatchdogCheck()
            }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func runWatchdogCheck() async {
        let df = Self.dateFormatter
        let cutoff = Date().addingTimeInterval(-Self.stuckThresholdSeconds)
        let cutoffStr = df.string(from: cutoff)
        let nowStr = df.string(from: Date())

        do {
            try await DatabaseManager.shared.asyncWrite { db in
                guard try db.tableExists("agent_sessions") else { return }

                // Find sessions that are active but haven't reported in > 5 min
                let stuckRows = try Row.fetchAll(db, sql: """
                    SELECT id FROM agent_sessions
                    WHERE status NOT IN ('completed', 'failed', 'interrupted', 'stuck')
                      AND last_activity_at < ?
                    """, arguments: [cutoffStr])

                for row in stuckRows {
                    guard let sessionId: String = row["id"] else { continue }

                    // Mark session as stuck
                    try db.execute(sql: """
                        UPDATE agent_sessions SET status = 'stuck'
                        WHERE id = ?
                        """, arguments: [sessionId])

                    // Insert attention event if that table exists
                    if try db.tableExists("agent_attention_events") {
                        let eventId = UUID().uuidString
                        try db.execute(sql: """
                            INSERT INTO agent_attention_events
                                (id, session_id, type, severity, message, created_at, acknowledged)
                            VALUES (?, ?, 'stuck', 'warning',
                                    'Session inactive for over 5 minutes',
                                    ?, 0)
                            """, arguments: [eventId, sessionId, nowStr])
                    }
                }
            }
        } catch {
            wtLog("[AgentStatusStore] Watchdog check failed: \(error)")
        }
    }

    // MARK: - Background Fetch

    private struct FetchResult: Sendable {
        let active: [AgentSession]
        let completed: [AgentSession]
    }

    /// All DB reads via asyncRead — runs on GRDB's reader queue, not MainActor.
    private static func fetchAllAsync() async throws -> FetchResult {
        let active = try await DatabaseManager.shared.asyncRead { db -> [AgentSession] in
            guard try db.tableExists("agent_sessions") else { return [] }
            return try AgentSession.fetchAll(db, sql: """
                SELECT * FROM agent_sessions
                WHERE status NOT IN ('completed', 'failed', 'interrupted')
                ORDER BY last_activity_at DESC
                """)
        }

        let completed = try await DatabaseManager.shared.asyncRead { db -> [AgentSession] in
            guard try db.tableExists("agent_sessions") else { return [] }
            return try AgentSession.fetchAll(db, sql: """
                SELECT * FROM agent_sessions
                WHERE status IN ('completed', 'failed')
                ORDER BY completed_at DESC
                LIMIT 20
                """)
        }

        return FetchResult(active: active, completed: completed)
    }
}
