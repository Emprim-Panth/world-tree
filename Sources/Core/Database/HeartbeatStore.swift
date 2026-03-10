import Foundation
import GRDB

// MARK: - Heartbeat Signal Model

struct HeartbeatSignal: Identifiable, Sendable {
    let id: String
    let category: String
    let content: String
    let project: String?
    let actionTaken: String?
    let timestamp: Date?
}

// MARK: - Heartbeat Run Model

struct HeartbeatRun: Identifiable, Sendable {
    let id: String
    let intensity: String
    let startedAt: Date?
    let completedAt: Date?
    let signalsFound: Int
    let dispatchesMade: Int
    let summary: String?
}

// MARK: - Dispatch Job Model

struct CrewDispatchJob: Identifiable, Sendable {
    let id: String
    let project: String
    let model: String
    let crewAgent: String
    let prompt: String
    let ticketId: String?
    let status: String          // pending, running, completed, failed
    let attempts: Int
    let maxAttempts: Int
    let lastError: String?
    let createdAt: Date?

    var agentIcon: String {
        switch crewAgent.lowercased() {
        case "geordi":  return "wrench.and.screwdriver"
        case "data":    return "chart.bar"
        case "scotty":  return "hammer"
        case "worf":    return "shield"
        case "torres":  return "gearshape.2"
        case "spock":   return "brain"
        case "dax":     return "book"
        case "uhura":   return "antenna.radiowaves.left.and.right"
        default:        return "person.circle"
        }
    }

    var statusColor: String {
        switch status {
        case "running":   return "blue"
        case "pending":   return "orange"
        case "completed": return "green"
        case "failed":    return "red"
        default:          return "gray"
        }
    }

    /// First ~60 chars of the prompt, cleaned up for display
    var shortPrompt: String {
        let cleaned = prompt.components(separatedBy: "\n").first ?? prompt
        return cleaned.count > 80 ? String(cleaned.prefix(80)) + "…" : cleaned
    }
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

    // Crew dispatch queue
    @Published private(set) var dispatchJobs: [CrewDispatchJob] = []
    @Published private(set) var recentRuns: [HeartbeatRun] = []

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()

    private init() {}

    // MARK: - Refresh

    /// Async refresh — runs DB reads on GRDB's reader queue, not MainActor.
    func refreshAsync() async {
        do {
            let result = try await Self.fetchAllAsync()
            self.lastHeartbeat = result.lastHeartbeat
            self.lastIntensity = result.lastIntensity
            self.lastSignalCount = result.lastSignalCount
            self.lastDispatchCount = result.lastDispatchCount
            self.activeDispatches = result.activeDispatches
            self.dispatchJobs = result.dispatchJobs
            self.recentRuns = result.recentRuns
            self.recentSignals = result.recentSignals
        } catch {
            wtLog("[HeartbeatStore] Error refreshing async: \(error)")
        }
    }

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

            // Crew dispatch queue — pending + running + last 20 completed/failed
            let jobRows = try DatabaseManager.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, project, model, crew_agent, prompt, ticket_id,
                           status, attempts, max_attempts, last_error, created_at
                    FROM dispatch_queue
                    ORDER BY
                        CASE status
                            WHEN 'running' THEN 0
                            WHEN 'pending' THEN 1
                            ELSE 2
                        END,
                        created_at DESC
                    LIMIT 40
                    """)
            }
            dispatchJobs = jobRows.map { row in
                let dateStr: String? = row["created_at"]
                return CrewDispatchJob(
                    id: row["id"] ?? UUID().uuidString,
                    project: row["project"] ?? "",
                    model: row["model"] ?? "sonnet",
                    crewAgent: row["crew_agent"] ?? "unknown",
                    prompt: row["prompt"] ?? "",
                    ticketId: row["ticket_id"],
                    status: row["status"] ?? "unknown",
                    attempts: row["attempts"] ?? 0,
                    maxAttempts: row["max_attempts"] ?? 3,
                    lastError: row["last_error"],
                    createdAt: dateStr.flatMap { Self.dateFormatter.date(from: $0) }
                )
            }

            // Recent heartbeat runs (last 10)
            let runRows = try DatabaseManager.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, intensity, started_at, completed_at,
                           signals_found, dispatches_made, summary
                    FROM heartbeat_runs
                    ORDER BY started_at DESC LIMIT 10
                    """)
            }
            recentRuns = runRows.map { row in
                let startStr: String? = row["started_at"]
                let endStr: String? = row["completed_at"]
                return HeartbeatRun(
                    id: row["id"] ?? UUID().uuidString,
                    intensity: row["intensity"] ?? "unknown",
                    startedAt: startStr.flatMap { Self.dateFormatter.date(from: $0) },
                    completedAt: endStr.flatMap { Self.dateFormatter.date(from: $0) },
                    signalsFound: row["signals_found"] ?? 0,
                    dispatchesMade: row["dispatches_made"] ?? 0,
                    summary: row["summary"]
                )
            }

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

    // MARK: - Background Fetch

    private struct FetchResult: Sendable {
        let lastHeartbeat: Date?
        let lastIntensity: String
        let lastSignalCount: Int
        let lastDispatchCount: Int
        let activeDispatches: Int
        let dispatchJobs: [CrewDispatchJob]
        let recentRuns: [HeartbeatRun]
        let recentSignals: [HeartbeatSignal]
    }

    /// All DB reads via asyncRead — runs on GRDB's reader queue, not MainActor.
    private static func fetchAllAsync() async throws -> FetchResult {
        let df = dateFormatter

        let lastRunRow = try await DatabaseManager.shared.asyncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT id, intensity, started_at, completed_at, signals_found, dispatches_made, summary
                FROM heartbeat_runs
                ORDER BY started_at DESC LIMIT 1
                """)
        }

        var lastHeartbeat: Date?
        var lastIntensity = "unknown"
        var lastSignalCount = 0
        var lastDispatchCount = 0

        if let row = lastRunRow {
            let startedStr: String? = row["started_at"]
            lastHeartbeat = startedStr.flatMap { df.date(from: $0) }
            lastIntensity = row["intensity"] ?? "unknown"
            lastSignalCount = row["signals_found"] ?? 0
            lastDispatchCount = row["dispatches_made"] ?? 0
        }

        let activeDispatches = try await DatabaseManager.shared.asyncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM canvas_dispatches
                WHERE status IN ('queued', 'running')
                """) ?? 0
        }

        let jobRows = try await DatabaseManager.shared.asyncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT id, project, model, crew_agent, prompt, ticket_id,
                       status, attempts, max_attempts, last_error, created_at
                FROM dispatch_queue
                ORDER BY
                    CASE status
                        WHEN 'running' THEN 0
                        WHEN 'pending' THEN 1
                        ELSE 2
                    END,
                    created_at DESC
                LIMIT 40
                """)
        }
        let dispatchJobs = jobRows.map { row in
            let dateStr: String? = row["created_at"]
            return CrewDispatchJob(
                id: row["id"] ?? UUID().uuidString,
                project: row["project"] ?? "",
                model: row["model"] ?? "sonnet",
                crewAgent: row["crew_agent"] ?? "unknown",
                prompt: row["prompt"] ?? "",
                ticketId: row["ticket_id"],
                status: row["status"] ?? "unknown",
                attempts: row["attempts"] ?? 0,
                maxAttempts: row["max_attempts"] ?? 3,
                lastError: row["last_error"],
                createdAt: dateStr.flatMap { df.date(from: $0) }
            )
        }

        let runRows = try await DatabaseManager.shared.asyncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT id, intensity, started_at, completed_at,
                       signals_found, dispatches_made, summary
                FROM heartbeat_runs
                ORDER BY started_at DESC LIMIT 10
                """)
        }
        let recentRuns = runRows.map { row in
            let startStr: String? = row["started_at"]
            let endStr: String? = row["completed_at"]
            return HeartbeatRun(
                id: row["id"] ?? UUID().uuidString,
                intensity: row["intensity"] ?? "unknown",
                startedAt: startStr.flatMap { df.date(from: $0) },
                completedAt: endStr.flatMap { df.date(from: $0) },
                signalsFound: row["signals_found"] ?? 0,
                dispatchesMade: row["dispatches_made"] ?? 0,
                summary: row["summary"]
            )
        }

        let signalRows = try await DatabaseManager.shared.asyncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT id, category, content, project, action_taken, created_at
                FROM governance_journal
                ORDER BY created_at DESC
                LIMIT 20
                """)
        }
        let recentSignals = signalRows.map { row in
            let dateStr: String? = row["created_at"]
            return HeartbeatSignal(
                id: row["id"] ?? UUID().uuidString,
                category: row["category"] ?? "unknown",
                content: row["content"] ?? "",
                project: row["project"],
                actionTaken: row["action_taken"],
                timestamp: dateStr.flatMap { df.date(from: $0) }
            )
        }

        return FetchResult(
            lastHeartbeat: lastHeartbeat,
            lastIntensity: lastIntensity,
            lastSignalCount: lastSignalCount,
            lastDispatchCount: lastDispatchCount,
            activeDispatches: activeDispatches,
            dispatchJobs: dispatchJobs,
            recentRuns: recentRuns,
            recentSignals: recentSignals
        )
    }
}
