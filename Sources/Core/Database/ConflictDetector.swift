import Foundation
import GRDB

// MARK: - Conflict Detector

/// Detects when two or more active agents are touching the same file.
/// Runs off the main actor (DB reads async) then publishes results on MainActor.
@MainActor
final class ConflictDetector: ObservableObject {
    static let shared = ConflictDetector()

    @Published private(set) var activeConflicts: [FileConflict] = []

    private var debounceTask: Task<Void, Never>?

    private init() {}

    // MARK: - Models

    struct FileConflict: Identifiable {
        let id: String              // file_path used as stable ID
        let filePath: String
        let project: String
        let agents: [ConflictingAgent]
        let severity: ConflictSeverity
        let detectedAt: Date
    }

    struct ConflictingAgent: Identifiable {
        var id: String { sessionId }
        let sessionId: String
        let agentName: String?
        let lastTouchAt: Date
        let action: String          // edit, create, delete
    }

    enum ConflictSeverity {
        case active     // Both agents currently active and touching same file
        case recent     // One touched file in last 10 min, another is active
    }

    // MARK: - Public

    /// Run conflict detection immediately.
    func check() async {
        do {
            let conflicts = try await Self.detectConflicts()
            self.activeConflicts = conflicts

            // Write attention events for new conflicts
            await Self.writeAttentionEvents(for: conflicts)
        } catch {
            wtLog("[ConflictDetector] check failed: \(error)")
        }
    }

    /// Debounced check — cancels any pending check and schedules a new one after 2s.
    /// Used when a new file touch row is detected.
    func checkDebounced() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.check()
        }
    }

    // MARK: - Detection Query

    private static func detectConflicts() async throws -> [FileConflict] {
        let rows = try await DatabaseManager.shared.asyncRead { db -> [Row] in
            guard try db.tableExists("agent_file_touches"),
                  try db.tableExists("agent_sessions") else { return [] }

            return try Row.fetchAll(db, sql: """
                SELECT
                    ft1.file_path,
                    COALESCE(ft1.project, s1.project) as project,
                    ft1.session_id as session1,
                    ft1.agent_name as agent1,
                    ft1.touched_at as touch1,
                    ft1.action as action1,
                    ft2.session_id as session2,
                    ft2.agent_name as agent2,
                    ft2.touched_at as touch2,
                    ft2.action as action2
                FROM agent_file_touches ft1
                JOIN agent_file_touches ft2
                    ON ft1.file_path = ft2.file_path
                    AND ft1.session_id != ft2.session_id
                    AND ft1.action IN ('edit', 'create', 'delete')
                    AND ft2.action IN ('edit', 'create', 'delete')
                JOIN agent_sessions s1
                    ON s1.id = ft1.session_id
                    AND s1.status NOT IN ('completed', 'failed', 'interrupted')
                JOIN agent_sessions s2
                    ON s2.id = ft2.session_id
                    AND s2.status NOT IN ('completed', 'failed', 'interrupted')
                WHERE ft1.touched_at > datetime('now', '-10 minutes')
                  AND ft2.touched_at > datetime('now', '-10 minutes')
                  AND ft1.session_id < ft2.session_id  -- deduplicate pairs
                ORDER BY ft1.touched_at DESC
                """)
        }

        // Collapse rows into FileConflict structs (multiple agents per file)
        var conflictMap: [String: (project: String, agents: [ConflictingAgent], latestTouch: Date)] = [:]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone(identifier: "UTC")

        for row in rows {
            guard let filePath: String = row["file_path"] else { continue }
            let project: String = row["project"] ?? ""

            func parseDate(_ key: String) -> Date {
                if let s: String = row[key], let d = df.date(from: s) { return d }
                return Date()
            }

            let agent1 = ConflictingAgent(
                sessionId: row["session1"] ?? "",
                agentName: row["agent1"],
                lastTouchAt: parseDate("touch1"),
                action: row["action1"] ?? "edit"
            )
            let agent2 = ConflictingAgent(
                sessionId: row["session2"] ?? "",
                agentName: row["agent2"],
                lastTouchAt: parseDate("touch2"),
                action: row["action2"] ?? "edit"
            )

            if var existing = conflictMap[filePath] {
                // Add agents not already present
                let existingIds = Set(existing.agents.map(\.sessionId))
                if !existingIds.contains(agent1.sessionId) { existing.agents.append(agent1) }
                if !existingIds.contains(agent2.sessionId) { existing.agents.append(agent2) }
                existing.latestTouch = max(existing.latestTouch, agent1.lastTouchAt, agent2.lastTouchAt)
                conflictMap[filePath] = existing
            } else {
                let latest = max(agent1.lastTouchAt, agent2.lastTouchAt)
                conflictMap[filePath] = (project: project, agents: [agent1, agent2], latestTouch: latest)
            }
        }

        return conflictMap.map { filePath, data in
            FileConflict(
                id: filePath,
                filePath: filePath,
                project: data.project,
                agents: data.agents.sorted { $0.lastTouchAt > $1.lastTouchAt },
                severity: .active,
                detectedAt: data.latestTouch
            )
        }.sorted { $0.detectedAt > $1.detectedAt }
    }

    // MARK: - Attention Events

    private static func writeAttentionEvents(for conflicts: [FileConflict]) async {
        guard !conflicts.isEmpty else { return }
        do {
            try await DatabaseManager.shared.asyncWrite { db in
                guard try db.tableExists("agent_attention_events"),
                      try db.tableExists("agent_sessions") else { return }

                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                df.timeZone = TimeZone(identifier: "UTC")
                let now = df.string(from: Date())

                for conflict in conflicts {
                    guard let firstAgent = conflict.agents.first else { continue }

                    // Check if an unacknowledged conflict event already exists for this file+session pair
                    let exists = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM agent_attention_events
                        WHERE type = 'conflict'
                          AND session_id = ?
                          AND message LIKE ?
                          AND acknowledged = 0
                        """, arguments: [firstAgent.sessionId, "%\(conflict.filePath)%"]) ?? 0

                    guard exists == 0 else { continue }

                    let agentNames = conflict.agents.compactMap(\.agentName).joined(separator: " and ")
                    let message = "File conflict: \(conflict.filePath) being edited by \(agentNames)"
                    let metadata = "{\"file\": \"\(conflict.filePath)\", \"agents\": [\"\(conflict.agents.compactMap(\.agentName).joined(separator: "\", \""))\"]}"

                    try db.execute(sql: """
                        INSERT INTO agent_attention_events
                            (id, session_id, type, severity, message, metadata, created_at, acknowledged)
                        VALUES (?, ?, 'conflict', 'warning', ?, ?, ?, 0)
                        """, arguments: [UUID().uuidString, firstAgent.sessionId, message, metadata, now])
                }
            }
        } catch {
            wtLog("[ConflictDetector] writeAttentionEvents failed: \(error)")
        }
    }
}
