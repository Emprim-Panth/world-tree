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

/// Store that connects to ~/.cortana/compass.db.
/// Supports both reads and writes — goal, phase, blockers, and decisions
/// can be edited from the Command Center UI.
@MainActor
final class CompassStore: ObservableObject {
    static let shared = CompassStore()

    @Published private(set) var states: [String: CompassState] = [:]
    @Published private(set) var lastRefresh: Date?

    private var dbPool: DatabasePool?

    /// Valid phases for project lifecycle
    static let phases = ["exploring", "planning", "implementing", "debugging", "testing", "shipping"]

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
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA busy_timeout = 5000")
            }
            dbPool = try DatabasePool(path: path, configuration: config)
            wtLog("[CompassStore] Connected to compass.db (read-write)")
        } catch {
            wtLog("[CompassStore] Failed to open compass.db: \(error)")
        }
    }

    // MARK: - Write Operations

    /// Update the current goal for a project
    func updateGoal(_ goal: String, for project: String) {
        guard let dbPool else { return }
        do {
            try dbPool.write { db in
                try db.execute(
                    sql: "UPDATE compass_state SET current_goal = ?, updated_at = datetime('now') WHERE project = ?",
                    arguments: [goal.isEmpty ? nil : goal, project]
                )
            }
            logEvent(project: project, type: "goal_update", summary: "Goal updated: \(goal)")
            refresh()
            wtLog("[CompassStore] Updated goal for \(project)")
        } catch {
            wtLog("[CompassStore] Failed to update goal for \(project): \(error)")
        }
    }

    /// Update the current phase for a project
    func updatePhase(_ phase: String, for project: String) {
        guard let dbPool else { return }
        do {
            try dbPool.write { db in
                try db.execute(
                    sql: "UPDATE compass_state SET current_phase = ?, updated_at = datetime('now') WHERE project = ?",
                    arguments: [phase, project]
                )
            }
            logEvent(project: project, type: "phase_change", summary: "Phase changed to \(phase)")
            refresh()
            wtLog("[CompassStore] Updated phase for \(project) to \(phase)")
        } catch {
            wtLog("[CompassStore] Failed to update phase for \(project): \(error)")
        }
    }

    /// Add a blocker to a project
    func addBlocker(_ blocker: String, for project: String) {
        guard let dbPool else { return }
        let trimmed = blocker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            let current = state(for: project)?.blockers ?? []
            guard !current.contains(trimmed) else { return }

            var updated = current
            updated.append(trimmed)
            let json = try JSONEncoder().encode(updated)
            let jsonStr = String(data: json, encoding: .utf8) ?? "[]"

            try dbPool.write { db in
                try db.execute(
                    sql: "UPDATE compass_state SET open_blockers = ?, updated_at = datetime('now') WHERE project = ?",
                    arguments: [jsonStr, project]
                )
            }
            logEvent(project: project, type: "blocker_added", summary: "Blocker added: \(trimmed)")
            refresh()
            wtLog("[CompassStore] Added blocker for \(project): \(trimmed)")
        } catch {
            wtLog("[CompassStore] Failed to add blocker for \(project): \(error)")
        }
    }

    /// Remove a blocker from a project
    func removeBlocker(_ blocker: String, for project: String) {
        guard let dbPool else { return }
        do {
            var current = state(for: project)?.blockers ?? []
            current.removeAll { $0 == blocker }
            let json = try JSONEncoder().encode(current)
            let jsonStr = String(data: json, encoding: .utf8) ?? "[]"

            try dbPool.write { db in
                try db.execute(
                    sql: "UPDATE compass_state SET open_blockers = ?, updated_at = datetime('now') WHERE project = ?",
                    arguments: [jsonStr, project]
                )
            }
            logEvent(project: project, type: "blocker_resolved", summary: "Blocker resolved: \(blocker)")
            refresh()
            wtLog("[CompassStore] Removed blocker for \(project): \(blocker)")
        } catch {
            wtLog("[CompassStore] Failed to remove blocker for \(project): \(error)")
        }
    }

    /// Log a decision with rationale for a project
    func logDecision(_ decision: String, for project: String) {
        guard let dbPool else { return }
        let trimmed = decision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            var current = state(for: project)?.decisions ?? []
            current.insert(trimmed, at: 0)
            // Keep last 10 decisions
            if current.count > 10 { current = Array(current.prefix(10)) }
            let json = try JSONEncoder().encode(current)
            let jsonStr = String(data: json, encoding: .utf8) ?? "[]"

            try dbPool.write { db in
                try db.execute(
                    sql: "UPDATE compass_state SET recent_decisions = ?, updated_at = datetime('now') WHERE project = ?",
                    arguments: [jsonStr, project]
                )
            }
            logEvent(project: project, type: "decision", summary: trimmed)
            refresh()
            wtLog("[CompassStore] Logged decision for \(project): \(trimmed)")
        } catch {
            wtLog("[CompassStore] Failed to log decision for \(project): \(error)")
        }
    }

    /// Update the last session summary for a project (called by ContextServer on POST /session/summary)
    func updateLastSessionSummary(_ summary: String, for project: String) {
        guard let dbPool else { return }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try dbPool.write { db in
                try db.execute(
                    sql: "UPDATE compass_state SET last_session_summary = ?, updated_at = datetime('now') WHERE project = ?",
                    arguments: [trimmed, project]
                )
            }
            refresh()
            wtLog("[CompassStore] Updated session summary for \(project)")
        } catch {
            wtLog("[CompassStore] Failed to update session summary for \(project): \(error)")
        }
    }

    /// Write an event to compass_log
    private func logEvent(project: String, type: String, summary: String) {
        guard let dbPool else { return }
        do {
            try dbPool.write { db in
                try db.execute(
                    sql: "INSERT INTO compass_log (project, event_type, summary, details, created_at) VALUES (?, ?, ?, ?, datetime('now'))",
                    arguments: [project, type, summary, "via World Tree"]
                )
            }
        } catch {
            wtLog("[CompassStore] Failed to log event: \(error)")
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

    /// Get state for a specific project (case-insensitive fallback).
    func state(for project: String) -> CompassState? {
        if let direct = states[project] { return direct }
        let lower = project.lowercased()
        return states.values.first { $0.project.lowercased() == lower }
    }

    /// Build a keyed snapshot for a specific set of project names, using
    /// case-insensitive matching against the compass DB. Keys in the result
    /// are exactly the provided names — safe for direct dictionary lookup.
    func snapshot(for projectNames: [String]) -> [String: CompassState] {
        var result: [String: CompassState] = [:]
        for name in projectNames {
            if let s = state(for: name) { result[name] = s }
        }
        return result
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
