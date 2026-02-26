import Foundation
import GRDB

/// Per-project aggregated metrics from dispatch history.
struct ProjectMetrics: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "canvas_project_metrics"

    let project: String
    var totalDispatches: Int
    var successfulDispatches: Int
    var failedDispatches: Int
    var totalTokensIn: Int
    var totalTokensOut: Int
    var totalDurationSeconds: Double
    var lastActivityAt: Date?
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case project
        case totalDispatches = "total_dispatches"
        case successfulDispatches = "successful_dispatches"
        case failedDispatches = "failed_dispatches"
        case totalTokensIn = "total_tokens_in"
        case totalTokensOut = "total_tokens_out"
        case totalDurationSeconds = "total_duration_seconds"
        case lastActivityAt = "last_activity_at"
        case updatedAt = "updated_at"
    }

    // MARK: - Computed

    var successRate: Double {
        guard totalDispatches > 0 else { return 0 }
        return Double(successfulDispatches) / Double(totalDispatches)
    }

    var totalTokens: Int { totalTokensIn + totalTokensOut }

    var avgDuration: TimeInterval {
        guard totalDispatches > 0 else { return 0 }
        return totalDurationSeconds / Double(totalDispatches)
    }
}

// MARK: - Metrics Service

/// Records and queries per-project metrics from completed dispatches.
@MainActor
enum ProjectMetricsService {

    /// Record a completed dispatch into project metrics.
    static func record(dispatch: WorldTreeDispatch) {
        guard dispatch.status == .completed || dispatch.status == .failed else { return }

        let duration = dispatch.duration ?? 0
        let tokensIn = dispatch.resultTokensIn ?? 0
        let tokensOut = dispatch.resultTokensOut ?? 0
        let isSuccess = dispatch.status == .completed

        do {
            try DatabaseManager.shared.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO canvas_project_metrics
                        (project, total_dispatches, successful_dispatches, failed_dispatches,
                         total_tokens_in, total_tokens_out, total_duration_seconds,
                         last_activity_at, updated_at)
                        VALUES (?, 1, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))
                        ON CONFLICT(project) DO UPDATE SET
                            total_dispatches = total_dispatches + 1,
                            successful_dispatches = successful_dispatches + ?,
                            failed_dispatches = failed_dispatches + ?,
                            total_tokens_in = total_tokens_in + ?,
                            total_tokens_out = total_tokens_out + ?,
                            total_duration_seconds = total_duration_seconds + ?,
                            last_activity_at = datetime('now'),
                            updated_at = datetime('now')
                        """,
                    arguments: [
                        dispatch.project,
                        isSuccess ? 1 : 0, isSuccess ? 0 : 1,
                        tokensIn, tokensOut, duration,
                        // ON CONFLICT update values
                        isSuccess ? 1 : 0, isSuccess ? 0 : 1,
                        tokensIn, tokensOut, duration
                    ]
                )
            }
        } catch {
            wtLog("[ProjectMetrics] Failed to record: \(error)")
        }
    }

    /// Get metrics for a specific project
    static func metrics(for project: String) -> ProjectMetrics? {
        try? DatabaseManager.shared.read { db in
            try ProjectMetrics
                .filter(Column("project") == project)
                .fetchOne(db)
        }
    }

    /// Get all project metrics
    static func allMetrics() -> [ProjectMetrics] {
        (try? DatabaseManager.shared.read { db in
            try ProjectMetrics
                .order(Column("last_activity_at").desc)
                .fetchAll(db)
        }) ?? []
    }
}
