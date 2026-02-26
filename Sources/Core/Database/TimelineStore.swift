import Foundation
import GRDB

/// Provides a unified timeline across all event sources in the Cortana ecosystem.
/// Queries sessions, dispatches, knowledge, archives, and graph changes.
@MainActor
final class TimelineStore {
    static let shared = TimelineStore()

    private var db: DatabaseManager { .shared }

    private init() {}

    /// Get unified timeline events from all sources.
    func getTimeline(
        project: String? = nil,
        eventTypes: Set<UnifiedTimelineEvent.EventType>? = nil,
        since: Date? = nil,
        limit: Int = 50
    ) async throws -> [UnifiedTimelineEvent] {
        try await db.asyncRead { db in
            var events: [UnifiedTimelineEvent] = []

            let sinceStr = since.map { ISO8601DateFormatter().string(from: $0) } ?? "2000-01-01"

            // Preflight: one query to check all optional tables at once.
            let existingTables = try Set(String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name IN ('canvas_dispatches', 'knowledge', 'conversation_archive')
                """))

            // 1. Sessions
            if eventTypes == nil || eventTypes!.contains(.session) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT s.id, s.started_at, s.working_directory, s.description,
                           (SELECT COUNT(*) FROM messages WHERE session_id = s.id) as msg_count
                    FROM sessions s
                    WHERE s.started_at > ?
                    ORDER BY s.started_at DESC
                    LIMIT ?
                    """, arguments: [sinceStr, limit])

                for row in rows {
                    let id: String = row["id"]
                    let wd: String = row["working_directory"] ?? ""
                    let desc: String = row["description"] ?? ""
                    let msgCount: Int = row["msg_count"]
                    let projectName = Self.extractProject(from: wd)

                    if let p = project, let pn = projectName, pn.lowercased() != p.lowercased() {
                        continue
                    }

                    if let ts = Self.parseDate(row["started_at"]) {
                        events.append(UnifiedTimelineEvent(
                            id: "session-\(id)",
                            timestamp: ts,
                            eventType: .session,
                            project: projectName,
                            summary: desc.isEmpty ? "\(msgCount) messages" : "\(desc) (\(msgCount) msgs)",
                            metadata: ["session_id": id, "working_directory": wd]
                        ))
                    }
                }
            }

            // 2. Dispatches
            if eventTypes == nil || eventTypes!.contains(.dispatch) {
                if existingTables.contains("canvas_dispatches") {
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT id, project, message, status, model, created_at
                        FROM canvas_dispatches
                        WHERE created_at > ?
                        ORDER BY created_at DESC
                        LIMIT ?
                        """, arguments: [sinceStr, limit])

                    for row in rows {
                        let id: String = row["id"]
                        let proj: String = row["project"]
                        let msg: String = row["message"]
                        let status: String = row["status"]

                        if let p = project, proj.lowercased() != p.lowercased() { continue }

                        if let ts = Self.parseDate(row["created_at"]) {
                            events.append(UnifiedTimelineEvent(
                                id: "dispatch-\(id)",
                                timestamp: ts,
                                eventType: .dispatch,
                                project: proj,
                                summary: "[\(status)] \(msg.prefix(100))",
                                metadata: ["dispatch_id": id, "status": status]
                            ))
                        }
                    }
                }
            }

            // 3. Knowledge entries
            if eventTypes == nil || eventTypes!.contains(.knowledgeAdd) {
                if existingTables.contains("knowledge") {
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT id, type, title, project, created_at, heat_score
                        FROM knowledge
                        WHERE is_active = 1 AND created_at > ?
                        ORDER BY created_at DESC
                        LIMIT ?
                        """, arguments: [sinceStr, limit])

                    for row in rows {
                        let id: String = row["id"]
                        let type: String = row["type"]
                        let title: String = row["title"]
                        let proj: String? = row["project"]
                        let heat: Double = row["heat_score"] ?? 1.0

                        if let p = project, let kp = proj, kp.lowercased() != p.lowercased() { continue }

                        if let ts = Self.parseDate(row["created_at"]) {
                            events.append(UnifiedTimelineEvent(
                                id: "knowledge-\(id)",
                                timestamp: ts,
                                eventType: .knowledgeAdd,
                                project: proj,
                                summary: "[\(type.uppercased())] \(title) (heat: \(String(format: "%.1f", heat)))",
                                metadata: ["knowledge_id": id, "type": type]
                            ))
                        }
                    }
                }
            }

            // 4. Conversation archives
            if eventTypes == nil || eventTypes!.contains(.archival) {
                if existingTables.contains("conversation_archive") {
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT session_id, project, message_count, token_estimate,
                               compression_ratio, archived_at
                        FROM conversation_archive
                        WHERE archived_at > ?
                        ORDER BY archived_at DESC
                        LIMIT ?
                        """, arguments: [sinceStr, limit])

                    for row in rows {
                        let sid: String = row["session_id"]
                        let proj: String? = row["project"]
                        let msgCount: Int = row["message_count"] ?? 0
                        let tokens: Int = row["token_estimate"] ?? 0

                        if let p = project, let ap = proj, ap.lowercased() != p.lowercased() { continue }

                        if let ts = Self.parseDate(row["archived_at"]) {
                            events.append(UnifiedTimelineEvent(
                                id: "archive-\(sid)",
                                timestamp: ts,
                                eventType: .archival,
                                project: proj,
                                summary: "Archived: \(msgCount) msgs, ~\(tokens) tokens",
                                metadata: ["session_id": sid]
                            ))
                        }
                    }
                }
            }

            // Sort all events by timestamp descending
            events.sort { $0.timestamp > $1.timestamp }

            // Apply limit
            return Array(events.prefix(limit))
        }
    }

    // MARK: - Helpers

    nonisolated private static func extractProject(from workingDirectory: String) -> String? {
        let parts = workingDirectory.replacingOccurrences(
            of: NSHomeDirectory(), with: "~"
        ).split(separator: "/")
        for (i, part) in parts.enumerated() {
            if (part == "Development" || part == "development") && i + 1 < parts.count {
                return String(parts[i + 1])
            }
        }
        return nil
    }

    nonisolated private static func parseDate(_ value: DatabaseValue?) -> Date? {
        guard let str = String.fromDatabaseValue(value ?? .null) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: str) { return date }
        // Fallback for non-ISO formats
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.date(from: str)
    }
}
