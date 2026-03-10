import Foundation
import GRDB

// MARK: - Compass State Model

/// Mirrors the compass_state table in ~/.cortana/compass.db (written by cortana-core MCP).
/// World Tree reads this read-only — all writes happen through compass_update MCP tool.
struct CompassState: Codable, FetchableRecord {
    let project: String
    let path: String?
    let domain: String?
    let stack: String?
    let currentGoal: String?
    let currentPhase: String?
    let activeFiles: String?     // JSON array
    let openBlockers: String?    // JSON array
    let recentDecisions: String? // JSON array
    let lastSessionSummary: String?
    let lastSessionDate: String?
    let gitBranch: String?
    let gitDirty: Int
    let gitUncommittedCount: Int
    let gitLastCommit: String?
    let gitLastCommitDate: String?
    let openTicketsCount: Int
    let blockedTicketsCount: Int
    let nextTicket: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case project, path, domain, stack
        case currentGoal = "current_goal"
        case currentPhase = "current_phase"
        case activeFiles = "active_files"
        case openBlockers = "open_blockers"
        case recentDecisions = "recent_decisions"
        case lastSessionSummary = "last_session_summary"
        case lastSessionDate = "last_session_date"
        case gitBranch = "git_branch"
        case gitDirty = "git_dirty"
        case gitUncommittedCount = "git_uncommitted_count"
        case gitLastCommit = "git_last_commit"
        case gitLastCommitDate = "git_last_commit_date"
        case openTicketsCount = "open_tickets_count"
        case blockedTicketsCount = "blocked_tickets_count"
        case nextTicket = "next_ticket"
        case updatedAt = "updated_at"
    }

    // MARK: - Computed Properties

    var blockers: [String] {
        guard let raw = openBlockers else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
    }

    var decisions: [String] {
        guard let raw = recentDecisions else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
    }

    var isStale: Bool {
        guard let dateStr = updatedAt else { return true }
        guard let date = parseDate(dateStr) else { return true }
        return Date().timeIntervalSince(date) > 600 // 10 min
    }

    var isDirty: Bool { gitDirty != 0 }

    var phaseDisplay: String { currentPhase ?? "unknown" }

    /// Attention score for sorting: higher = needs more attention
    var attentionScore: Int {
        var score = 0
        if isDirty { score += 30 }
        if gitUncommittedCount > 10 { score += 15 }
        if blockedTicketsCount > 0 { score += 25 }
        if openTicketsCount > 5 { score += 10 }
        if !blockers.isEmpty { score += 20 }
        return min(score, 100)
    }

    private func parseDate(_ str: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: str) { return d }
        // Try without fractional seconds
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: str) { return d }
        // Try SQLite datetime format
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone(identifier: "UTC")
        return df.date(from: str)
    }
}

// MARK: - Compass Event Model

struct CompassEvent: Codable, FetchableRecord, Identifiable {
    let id: Int
    let project: String
    let eventType: String
    let summary: String
    let details: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, project, summary, details
        case eventType = "event_type"
        case createdAt = "created_at"
    }
}

// MARK: - Compass Store

/// Read-only store that connects to ~/.cortana/compass.db.
/// All state is written by cortana-core's CompassService via MCP tools.
/// World Tree only reads — never writes to compass.db.
@MainActor
final class CompassStore: ObservableObject {
    static let shared = CompassStore()

    @Published private(set) var states: [String: CompassState] = [:]
    @Published private(set) var lastRefresh: Date?

    private var dbPool: DatabasePool?

    private init() {
        openDatabase()
    }

    // MARK: - Database Connection

    private func openDatabase() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.cortana/compass.db"

        guard FileManager.default.fileExists(atPath: path) else {
            wtLog("[CompassStore] compass.db not found at \(path) — Compass not yet initialized")
            return
        }

        do {
            var config = Configuration()
            config.readonly = true
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA busy_timeout = 3000")
            }
            dbPool = try DatabasePool(path: path, configuration: config)
            wtLog("[CompassStore] Connected to compass.db")
        } catch {
            wtLog("[CompassStore] Failed to open compass.db: \(error)")
        }
    }

    // MARK: - Queries

    /// Load all project states from compass.db
    func refresh() {
        guard let dbPool else {
            // Try opening again in case it was created since last attempt
            openDatabase()
            guard self.dbPool != nil else { return }
            refresh()
            return
        }

        do {
            let rows = try dbPool.read { db in
                try CompassState.fetchAll(db, sql: "SELECT * FROM compass_state ORDER BY project")
            }

            var newStates: [String: CompassState] = [:]
            for row in rows {
                newStates[row.project] = row
            }
            states = newStates
            lastRefresh = Date()
        } catch {
            wtLog("[CompassStore] Failed to refresh: \(error)")
        }
    }

    /// Get state for a specific project
    func state(for project: String) -> CompassState? {
        states[project] ?? states.values.first { $0.project.lowercased() == project.lowercased() }
    }

    /// Get all states sorted by attention score (descending)
    var sortedByAttention: [CompassState] {
        states.values.sorted { $0.attentionScore > $1.attentionScore }
    }

    /// Get recent events for a project
    func events(for project: String, limit: Int = 10) -> [CompassEvent] {
        guard let dbPool else { return [] }

        do {
            return try dbPool.read { db in
                try CompassEvent.fetchAll(db, sql: """
                    SELECT * FROM compass_log
                    WHERE project = ?
                    ORDER BY created_at DESC
                    LIMIT ?
                    """, arguments: [project, limit])
            }
        } catch {
            wtLog("[CompassStore] Failed to fetch events for \(project): \(error)")
            return []
        }
    }
}
