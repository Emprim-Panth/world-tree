import Foundation
import GRDB
import Observation

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
@Observable
final class HeartbeatStore {
    static let shared = HeartbeatStore()

    private(set) var lastHeartbeat: Date?
    private(set) var lastIntensity: String = "unknown"
    private(set) var lastSignalCount: Int = 0
    private(set) var lastDispatchCount: Int = 0
    private(set) var activeDispatches: Int = 0
    private(set) var recentSignals: [HeartbeatSignal] = []

    // Crew dispatch queue
    private(set) var dispatchJobs: [CrewDispatchJob] = []
    private(set) var recentRuns: [HeartbeatRun] = []

    // Date parsing delegated to DateParsing shared utility

    /// Read-only pool for the gateway DB (cortana.db) which holds live dispatch_queue.
    /// Opened lazily — returns nil if the file doesn't exist yet.
    static var gatewayPool: DatabasePool? = {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".cortana/cortana.db")
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var config = Configuration()
        config.readonly = true
        return try? DatabasePool(path: path, configuration: config)
    }()

    private init() {}

    // MARK: - Signal Queries

    /// Check if there's a recent unprocessed signal matching the given category.
    /// Used by EventRuleStore for heartbeat-triggered rules.
    func hasSignal(category: String) -> Bool {
        recentSignals.contains { $0.category == category }
    }

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
        let lastRunRow = try await DatabaseManager.shared.asyncRead { db -> Row? in
            guard try db.tableExists("heartbeat_runs") else { return nil }
            return try Row.fetchOne(db, sql: """
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
            lastHeartbeat = startedStr.flatMap { DateParsing.parse($0) }
            lastIntensity = row["intensity"] ?? "unknown"
            lastSignalCount = row["signals_found"] ?? 0
            lastDispatchCount = row["dispatches_made"] ?? 0
        }

        let activeDispatches = try await DatabaseManager.shared.asyncRead { db in
            guard try db.tableExists("canvas_dispatches") else { return 0 }
            return try Int.fetchOne(db, sql: """
                SELECT count(*) FROM canvas_dispatches
                WHERE status IN ('queued', 'running')
                """) ?? 0
        }

        // Read dispatch jobs from the gateway DB (cortana.db) — that's where live dispatches live.
        // Schema uses `message` (not `prompt`), `project` is a full path, `created_at` is a Unix ms timestamp.
        let dispatchJobs: [CrewDispatchJob]
        if let pool = Self.gatewayPool {
            let jobRows = try await pool.read { db in
                guard try db.tableExists("dispatch_queue") else { return [Row]() }
                return try Row.fetchAll(db, sql: """
                    SELECT id, project, model, source, message, status,
                           created_at, completed_at
                    FROM dispatch_queue
                    WHERE status IN ('running','pending','dispatched','failed','timed_out','blocked','completed')
                    ORDER BY
                        CASE status
                            WHEN 'running'    THEN 0
                            WHEN 'dispatched' THEN 1
                            WHEN 'pending'    THEN 2
                            WHEN 'failed'     THEN 3
                            WHEN 'timed_out'  THEN 4
                            WHEN 'blocked'    THEN 5
                            ELSE 6
                        END,
                        created_at DESC
                    LIMIT 80
                    """)
            }
            dispatchJobs = jobRows.map { row in
                // project is a full path like /Users/evanprimeau/Development/BookBuddy
                let fullPath: String = row["project"] ?? ""
                let lastComponent = (fullPath as NSString).lastPathComponent
                // If the path ends at the root dev folder or home, use "Workspace"
                let projectName: String
                if lastComponent.isEmpty || lastComponent == "Development" || lastComponent == "evanprimeau" {
                    projectName = "Workspace"
                } else {
                    projectName = lastComponent
                }
                // created_at is Unix milliseconds (Int64)
                let createdMs: Int64? = row["created_at"]
                let createdAt = createdMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
                // source maps roughly to crew agent role
                let source: String = row["source"] ?? ""
                return CrewDispatchJob(
                    id: row["id"] ?? UUID().uuidString,
                    project: projectName,
                    model: row["model"] ?? "claude",
                    crewAgent: source,
                    prompt: row["message"] ?? "",
                    ticketId: nil,
                    status: row["status"] ?? "unknown",
                    attempts: 1,
                    maxAttempts: 3,
                    lastError: nil,
                    createdAt: createdAt
                )
            }
        } else {
            // Gateway DB not available — fall back to conversations.db legacy table
            let jobRows = try await DatabaseManager.shared.asyncRead { db in
                guard try db.tableExists("dispatch_queue") else { return [Row]() }
                return try Row.fetchAll(db, sql: """
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
                    createdAt: dateStr.flatMap { DateParsing.parse($0) }
                )
            }
        }

        let runRows = try await DatabaseManager.shared.asyncRead { db in
            guard try db.tableExists("heartbeat_runs") else { return [Row]() }
            return try Row.fetchAll(db, sql: """
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
                startedAt: startStr.flatMap { DateParsing.parse($0) },
                completedAt: endStr.flatMap { DateParsing.parse($0) },
                signalsFound: row["signals_found"] ?? 0,
                dispatchesMade: row["dispatches_made"] ?? 0,
                summary: row["summary"]
            )
        }

        let signalRows = try await DatabaseManager.shared.asyncRead { db in
            guard try db.tableExists("governance_journal") else { return [Row]() }
            return try Row.fetchAll(db, sql: """
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
                timestamp: dateStr.flatMap { DateParsing.parse($0) }
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
