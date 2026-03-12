import Foundation
import GRDB

/// Stores auto-detected decisions for user review before they're logged
/// to the Compass knowledge base via the gateway.
///
/// Lifecycle: detected -> pending -> (approved | rejected)
/// Approved decisions get logged to gateway memory as [DECISION] entries.
/// Rejected decisions are kept for 30 days (to avoid re-detecting the same text).
@MainActor
final class AutoDecisionStore {
    static let shared = AutoDecisionStore()

    private var db: DatabaseManager { .shared }

    private init() {}

    // MARK: - Models

    enum DecisionStatus: String, Codable, Sendable {
        case pending
        case approved
        case rejected
    }

    struct AutoDecision: Identifiable, Sendable {
        let id: String
        let sessionId: String
        let branchId: String?
        let project: String?
        let summary: String
        let rationale: String
        let context: String
        let confidence: Double
        let status: DecisionStatus
        let createdAt: Date
        let reviewedAt: Date?

        /// Formatted memory log entry for gateway submission.
        var memoryLogEntry: String {
            "[DECISION] \(summary) — \(rationale)"
        }
    }

    // MARK: - Write

    /// Save a batch of detected decisions as pending review.
    func savePending(
        decisions: [DecisionDetector.DetectedDecision],
        sessionId: String,
        branchId: String?,
        project: String?
    ) {
        guard !decisions.isEmpty else { return }

        do {
            try db.write { db in
                for decision in decisions {
                    let id = UUID().uuidString
                    try db.execute(
                        sql: """
                            INSERT INTO canvas_auto_decisions
                            (id, session_id, branch_id, project, summary, rationale, context, confidence, status, created_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', datetime('now'))
                            """,
                        arguments: [
                            id, sessionId, branchId, project,
                            decision.summary, decision.rationale,
                            decision.context, decision.confidence,
                        ]
                    )
                }
            }
            wtLog("[AutoDecisionStore] saved \(decisions.count) pending decisions for session \(sessionId)")
        } catch {
            wtLog("[AutoDecisionStore] savePending failed: \(error)")
        }
    }

    /// Check if a decision summary was already detected (to avoid duplicates).
    func isDuplicate(summary: String, sessionId: String) -> Bool {
        do {
            return try db.read { db in
                try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM canvas_auto_decisions
                        WHERE session_id = ? AND summary = ?
                    )
                    """, arguments: [sessionId, summary]) ?? false
            }
        } catch {
            return false
        }
    }

    // MARK: - Read

    /// Get all pending decisions for review, newest first.
    func getPending(limit: Int = 50) -> [AutoDecision] {
        do {
            return try db.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM canvas_auto_decisions
                    WHERE status = 'pending'
                    ORDER BY created_at DESC
                    LIMIT ?
                    """, arguments: [limit])
                return rows.compactMap { Self.decisionFromRow($0) }
            }
        } catch {
            wtLog("[AutoDecisionStore] getPending failed: \(error)")
            return []
        }
    }

    /// Get decisions by session.
    func getForSession(_ sessionId: String) -> [AutoDecision] {
        do {
            return try db.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM canvas_auto_decisions
                    WHERE session_id = ?
                    ORDER BY created_at DESC
                    """, arguments: [sessionId])
                return rows.compactMap { Self.decisionFromRow($0) }
            }
        } catch {
            wtLog("[AutoDecisionStore] getForSession failed: \(error)")
            return []
        }
    }

    /// Count of pending decisions (for badge display).
    func pendingCount() -> Int {
        do {
            return try db.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM canvas_auto_decisions WHERE status = 'pending'
                    """) ?? 0
            }
        } catch {
            return 0
        }
    }

    // MARK: - Review Actions

    /// Approve a decision — marks it approved and logs to gateway memory.
    func approve(_ decisionId: String) async {
        do {
            // Fetch the decision first
            let decision: AutoDecision? = try db.read { db in
                let row = try Row.fetchOne(db, sql: """
                    SELECT * FROM canvas_auto_decisions WHERE id = ?
                    """, arguments: [decisionId])
                return row.flatMap { Self.decisionFromRow($0) }
            }

            guard let decision else {
                wtLog("[AutoDecisionStore] approve: decision \(decisionId) not found")
                return
            }

            // Log to gateway memory
            await logToGateway(decision)

            // Mark as approved
            try db.write { db in
                try db.execute(
                    sql: """
                        UPDATE canvas_auto_decisions
                        SET status = 'approved', reviewed_at = datetime('now')
                        WHERE id = ?
                        """,
                    arguments: [decisionId]
                )
            }

            wtLog("[AutoDecisionStore] approved decision: \(decision.summary.prefix(80))")
        } catch {
            wtLog("[AutoDecisionStore] approve failed: \(error)")
        }
    }

    /// Reject a decision — keeps it in DB to prevent re-detection.
    func reject(_ decisionId: String) {
        do {
            try db.write { db in
                try db.execute(
                    sql: """
                        UPDATE canvas_auto_decisions
                        SET status = 'rejected', reviewed_at = datetime('now')
                        WHERE id = ?
                        """,
                    arguments: [decisionId]
                )
            }
            wtLog("[AutoDecisionStore] rejected decision \(decisionId)")
        } catch {
            wtLog("[AutoDecisionStore] reject failed: \(error)")
        }
    }

    /// Approve all pending decisions at once.
    func approveAll() async {
        let pending = getPending(limit: 100)
        for decision in pending {
            await approve(decision.id)
        }
    }

    /// Reject all pending decisions at once.
    func rejectAll() {
        do {
            try db.write { db in
                try db.execute(sql: """
                    UPDATE canvas_auto_decisions
                    SET status = 'rejected', reviewed_at = datetime('now')
                    WHERE status = 'pending'
                    """)
            }
            wtLog("[AutoDecisionStore] rejected all pending decisions")
        } catch {
            wtLog("[AutoDecisionStore] rejectAll failed: \(error)")
        }
    }

    // MARK: - Cleanup

    /// Remove old rejected decisions (30-day retention).
    func cleanup() {
        do {
            try db.write { db in
                try db.execute(sql: """
                    DELETE FROM canvas_auto_decisions
                    WHERE status = 'rejected'
                    AND reviewed_at < datetime('now', '-30 days')
                    """)
            }
        } catch {
            wtLog("[AutoDecisionStore] cleanup failed: \(error)")
        }
    }

    // MARK: - Gateway Integration

    /// Log an approved decision to the gateway memory system.
    private func logToGateway(_ decision: AutoDecision) async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.cortana/ark-gateway.toml"

        // Read auth token from gateway config
        guard let configData = FileManager.default.contents(atPath: configPath),
              let configStr = String(data: configData, encoding: .utf8),
              let token = Self.extractTOMLValue(key: "auth_token", from: configStr) else {
            wtLog("[AutoDecisionStore] cannot read gateway auth token — decision logged locally only")
            return
        }

        let client = GatewayClient(authToken: token)

        do {
            let entryId = try await client.logMemory(
                category: "DECISION",
                content: decision.memoryLogEntry,
                project: decision.project,
                tags: ["auto-detected", "confidence:\(String(format: "%.0f", decision.confidence * 100))"]
            )
            wtLog("[AutoDecisionStore] logged decision to gateway as entry \(entryId)")
        } catch {
            wtLog("[AutoDecisionStore] gateway log failed: \(error) — decision approved locally")
        }
    }

    /// Parse a value from TOML format (simple key = "value" lines).
    private nonisolated static func extractTOMLValue(key: String, from toml: String) -> String? {
        for line in toml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\(key)") {
                // Handle: key = "value" or key = value
                if let eqIdx = trimmed.firstIndex(of: "=") {
                    let valueStr = trimmed[trimmed.index(after: eqIdx)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // Strip surrounding quotes if present
                    if valueStr.hasPrefix("\"") && valueStr.hasSuffix("\"") && valueStr.count >= 2 {
                        return String(valueStr.dropFirst().dropLast())
                    }
                    return valueStr
                }
            }
        }
        return nil
    }

    // MARK: - Row Mapping

    private nonisolated static func decisionFromRow(_ row: Row) -> AutoDecision? {
        guard let id: String = row["id"],
              let sessionId: String = row["session_id"],
              let summary: String = row["summary"],
              let statusStr: String = row["status"] else {
            return nil
        }

        let status = DecisionStatus(rawValue: statusStr) ?? .pending

        // Parse dates
        let createdAt: Date
        if let dateStr: String = row["created_at"] {
            createdAt = parseSQLDate(dateStr) ?? Date()
        } else {
            createdAt = Date()
        }

        let reviewedAt: Date?
        if let dateStr: String = row["reviewed_at"] {
            reviewedAt = parseSQLDate(dateStr)
        } else {
            reviewedAt = nil
        }

        return AutoDecision(
            id: id,
            sessionId: sessionId,
            branchId: row["branch_id"],
            project: row["project"],
            summary: summary,
            rationale: row["rationale"] ?? "",
            context: row["context"] ?? "",
            confidence: row["confidence"] ?? 0.0,
            status: status,
            createdAt: createdAt,
            reviewedAt: reviewedAt
        )
    }

    private nonisolated static let sqlFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private nonisolated static func parseSQLDate(_ str: String) -> Date? {
        sqlFormatter.date(from: str)
    }
}
