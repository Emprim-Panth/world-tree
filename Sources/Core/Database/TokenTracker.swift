import Foundation
import GRDB

/// Writes per-turn token usage to `canvas_token_usage` and provides aggregate queries.
///
/// Called after each LLM response completes (`.done` event). Data feeds into
/// the Command Center dashboard and per-project cost analytics.
@MainActor
final class TokenTracker {
    static let shared = TokenTracker()

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
            wtLog("[TokenTracker] Failed to record usage: \(error)")
        }

        // Also update canvas_project_metrics if we can resolve the project
        updateProjectMetrics(sessionId: sessionId, inputTokens: inputTokens, outputTokens: outputTokens)
    }

    // MARK: - Queries

    /// Total tokens for a session (all branches).
    func totalsForSession(_ sessionId: String) -> (input: Int, output: Int) {
        let row = try? db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(input_tokens), 0) as total_in,
                       COALESCE(SUM(output_tokens), 0) as total_out
                FROM canvas_token_usage
                WHERE session_id = ?
                """, arguments: [sessionId])
        }
        guard let row else { return (0, 0) }
        return (row["total_in"] ?? 0, row["total_out"] ?? 0)
    }

    /// Total tokens for a project (resolved through canvas_branches -> canvas_trees).
    func totalsForProject(_ project: String) -> (input: Int, output: Int) {
        let row = try? db.read { db in
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
    }

    /// Recent usage entries for a branch (for timeline/detail view).
    func recentUsage(branchId: String, limit: Int = 20) -> [(input: Int, output: Int, model: String?, recordedAt: Date)] {
        guard let rows = try? db.read({ db in
            try Row.fetchAll(db, sql: """
                SELECT input_tokens, output_tokens, model, recorded_at
                FROM canvas_token_usage
                WHERE branch_id = ?
                ORDER BY recorded_at DESC
                LIMIT ?
                """, arguments: [branchId, limit])
        }) else { return [] }

        return rows.compactMap { row in
            guard let input: Int = row["input_tokens"],
                  let output: Int = row["output_tokens"] else { return nil }
            let model: String? = row["model"]
            let recordedAt: Date = row["recorded_at"] ?? Date()
            return (input, output, model, recordedAt)
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
            wtLog("[TokenTracker] Failed to update project metrics: \(error)")
        }
    }
}
