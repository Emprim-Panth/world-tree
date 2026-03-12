import Foundation
import GRDB

/// Writes per-turn token usage to `canvas_token_usage` and provides aggregate queries.
///
/// Called after each LLM response completes (`.done` event). Data feeds into
/// the Command Center dashboard and per-project cost analytics.
@MainActor
final class TokenStore {
    static let shared = TokenStore()

    private var db: DatabaseManager { .shared }

    private init() {}

    // MARK: - Record

    /// Record a single turn's token usage into `canvas_token_usage`.
    func record(
        sessionId: String,
        branchId: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheHitTokens: Int = 0,
        model: String
    ) {
        do {
            try db.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO canvas_token_usage
                            (session_id, branch_id, input_tokens, output_tokens, cache_hit_tokens, model, recorded_at)
                        VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
                        """,
                    arguments: [sessionId, branchId, inputTokens, outputTokens, cacheHitTokens, model]
                )
            }
        } catch {
            wtLog("[TokenStore] Failed to record usage: \(error)")
        }

        // Also update canvas_project_metrics if we can resolve the project
        updateProjectMetrics(sessionId: sessionId, inputTokens: inputTokens, outputTokens: outputTokens)
    }

    // MARK: - Queries

    /// Total tokens for a session (all branches).
    func totalsForSession(_ sessionId: String) -> (input: Int, output: Int) {
        do {
            let row = try db.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(input_tokens), 0) as total_in,
                           COALESCE(SUM(output_tokens), 0) as total_out
                    FROM canvas_token_usage
                    WHERE session_id = ?
                    """, arguments: [sessionId])
            }
            guard let row else { return (0, 0) }
            return (row["total_in"] ?? 0, row["total_out"] ?? 0)
        } catch {
            wtLog("[TokenStore] totalsForSession failed for \(sessionId): \(error)")
            return (0, 0)
        }
    }

    /// Total tokens for a project (resolved through canvas_branches -> canvas_trees).
    func totalsForProject(_ project: String) -> (input: Int, output: Int) {
        do {
            let row = try db.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(tu.input_tokens), 0) as total_in,
                           COALESCE(SUM(tu.output_tokens), 0) as total_out
                    FROM canvas_token_usage tu
                    JOIN canvas_branches b ON b.session_id = tu.session_id
                    JOIN canvas_trees t ON t.id = b.tree_id
                    WHERE t.project = ?
                    """, arguments: [project])
            }
            guard let row else { return (0, 0) }
            return (row["total_in"] ?? 0, row["total_out"] ?? 0)
        } catch {
            wtLog("[TokenStore] totalsForProject failed for '\(project)': \(error)")
            return (0, 0)
        }
    }

    /// Recent usage entries for a branch (for timeline/detail view).
    func recentUsage(branchId: String, limit: Int = 20) -> [(input: Int, output: Int, model: String?, recordedAt: Date)] {
        do {
            let rows = try db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT input_tokens, output_tokens, model, recorded_at
                    FROM canvas_token_usage
                    WHERE branch_id = ?
                    ORDER BY recorded_at DESC
                    LIMIT ?
                    """, arguments: [branchId, limit])
            }
            return rows.compactMap { row in
                guard let input: Int = row["input_tokens"],
                      let output: Int = row["output_tokens"] else { return nil }
                let model: String? = row["model"]
                let recordedAt: Date = row["recorded_at"] ?? Date()
                return (input, output, model, recordedAt)
            }
        } catch {
            wtLog("[TokenStore] recentUsage failed for branch \(branchId): \(error)")
            return []
        }
    }

    // MARK: - Dashboard Aggregates

    /// Burn rate per session over the last N minutes.
    func burnRates(windowMinutes: Int = 30) -> [SessionBurnRate] {
        do {
            let rows = try db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT
                        tu.session_id,
                        ss.project,
                        SUM(tu.input_tokens + tu.output_tokens) as total_tokens,
                        (julianday('now') - julianday(MIN(tu.recorded_at))) * 24 * 60 as minutes_elapsed,
                        CASE
                            WHEN (julianday('now') - julianday(MIN(tu.recorded_at))) * 24 * 60 > 0
                            THEN CAST(SUM(tu.input_tokens + tu.output_tokens) AS REAL)
                                 / ((julianday('now') - julianday(MIN(tu.recorded_at))) * 24 * 60)
                            ELSE 0
                        END as tokens_per_minute,
                        MIN(tu.recorded_at) as window_start
                    FROM canvas_token_usage tu
                    LEFT JOIN session_state ss ON ss.session_id = tu.session_id
                    WHERE tu.recorded_at > datetime('now', '-\(windowMinutes) minutes')
                    GROUP BY tu.session_id
                    ORDER BY tokens_per_minute DESC
                    """)
            }
            return rows.compactMap { row -> SessionBurnRate? in
                guard let sessionId: String = row["session_id"],
                      let total: Int = row["total_tokens"],
                      let rate: Double = row["tokens_per_minute"],
                      let windowStart: Date = row["window_start"] else { return nil }
                return SessionBurnRate(
                    sessionId: sessionId,
                    project: row["project"],
                    tokensPerMinute: rate,
                    totalTokens: total,
                    windowStart: windowStart
                )
            }
        } catch {
            wtLog("[TokenStore] burnRates failed: \(error)")
            return []
        }
    }

    /// Daily input+output totals for the last N days.
    func dailyTotals(days: Int = 7) -> [DailyTokenTotal] {
        do {
            let rows = try db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT
                        date(recorded_at) as day,
                        SUM(input_tokens) as input_tokens,
                        SUM(output_tokens) as output_tokens,
                        model
                    FROM canvas_token_usage
                    WHERE recorded_at > datetime('now', '-\(days) days')
                    GROUP BY date(recorded_at), model
                    ORDER BY day ASC
                    """)
            }
            return rows.compactMap { row -> DailyTokenTotal? in
                guard let dayStr: String = row["day"],
                      let input: Int = row["input_tokens"],
                      let output: Int = row["output_tokens"] else { return nil }
                // Parse "yyyy-MM-dd" string to Date
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.timeZone = TimeZone(identifier: "UTC")
                guard let date = formatter.date(from: dayStr) else { return nil }
                return DailyTokenTotal(date: date, inputTokens: input, outputTokens: output, model: row["model"])
            }
        } catch {
            wtLog("[TokenStore] dailyTotals failed: \(error)")
            return []
        }
    }

    /// Per-project aggregates from canvas_project_metrics.
    func projectSummaries() -> [ProjectTokenSummary] {
        do {
            let rows = try db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT
                        pm.project,
                        pm.total_tokens_in,
                        pm.total_tokens_out,
                        pm.last_activity_at,
                        COUNT(CASE WHEN s.status NOT IN ('completed','failed','interrupted') THEN 1 END) as active_sessions
                    FROM canvas_project_metrics pm
                    LEFT JOIN agent_sessions s ON s.project = pm.project
                    GROUP BY pm.project
                    ORDER BY pm.last_activity_at DESC
                    """)
            }
            return rows.compactMap { row -> ProjectTokenSummary? in
                guard let project: String = row["project"],
                      let totalIn: Int = row["total_tokens_in"],
                      let totalOut: Int = row["total_tokens_out"] else { return nil }
                return ProjectTokenSummary(
                    project: project,
                    totalIn: totalIn,
                    totalOut: totalOut,
                    activeSessions: row["active_sessions"] ?? 0,
                    lastActivityAt: row["last_activity_at"]
                )
            }
        } catch {
            wtLog("[TokenStore] projectSummaries failed: \(error)")
            return []
        }
    }

    /// Context window usage per active session (reads from agent_sessions).
    func contextUsage() -> [SessionContextUsage] {
        do {
            let rows = try db.read { db in
                guard try db.tableExists("agent_sessions") else { return [Row]() }
                return try Row.fetchAll(db, sql: """
                    SELECT id, project, context_used, context_max
                    FROM agent_sessions
                    WHERE status NOT IN ('completed', 'failed', 'interrupted')
                      AND context_max > 0
                    ORDER BY CAST(context_used AS REAL) / context_max DESC
                    """)
            }
            return rows.compactMap { row -> SessionContextUsage? in
                guard let sessionId: String = row["id"],
                      let used: Int = row["context_used"],
                      let max: Int = row["context_max"],
                      max > 0 else { return nil }
                return SessionContextUsage(
                    sessionId: sessionId,
                    project: row["project"],
                    estimatedUsed: used,
                    maxContext: max,
                    percentUsed: Double(used) / Double(max)
                )
            }
        } catch {
            wtLog("[TokenStore] contextUsage failed: \(error)")
            return []
        }
    }

    // MARK: - Project Metrics

    /// Update canvas_project_metrics with cumulative token counts.
    private func updateProjectMetrics(sessionId: String, inputTokens: Int, outputTokens: Int) {
        do {
            try db.write { db in
                // Resolve project from session -> branch -> tree
                let project: String? = try Row.fetchOne(db, sql: """
                    SELECT t.project FROM canvas_branches b
                    JOIN canvas_trees t ON t.id = b.tree_id
                    WHERE b.session_id = ?
                    LIMIT 1
                    """, arguments: [sessionId])?["project"]

                guard let project, !project.isEmpty else { return }

                try db.execute(
                    sql: """
                        INSERT INTO canvas_project_metrics (project, total_tokens_in, total_tokens_out, last_activity_at, updated_at)
                        VALUES (?, ?, ?, datetime('now'), datetime('now'))
                        ON CONFLICT(project) DO UPDATE SET
                            total_tokens_in = total_tokens_in + excluded.total_tokens_in,
                            total_tokens_out = total_tokens_out + excluded.total_tokens_out,
                            last_activity_at = datetime('now'),
                            updated_at = datetime('now')
                        """,
                    arguments: [project, inputTokens, outputTokens]
                )
            }
        } catch {
            wtLog("[TokenStore] Failed to update project metrics: \(error)")
        }
    }
}
