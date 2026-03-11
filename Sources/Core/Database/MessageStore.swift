import Foundation
import GRDB

/// Reads and writes messages from the existing `messages` table.
/// Uses the same INSERT pattern as cortana-core/src/memory/index.ts.
@MainActor
final class MessageStore {
    static let shared = MessageStore()

    private var db: DatabaseManager { .shared }

    private init() {}

    // MARK: - Read

    /// Lightweight existence check — uses SELECT EXISTS to avoid loading all messages.
    func hasMessages(sessionId: String) -> Bool {
        (try? db.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM messages WHERE session_id = ?)
                """, arguments: [sessionId])
        }) ?? false
    }

    /// Get messages for a session, with branch fork indicators.
    /// When a limit is applied, returns the *newest* N messages in chronological order.
    func getMessages(sessionId: String, limit: Int = 500) throws -> [Message] {
        try db.read { db in
            let sql = """
                SELECT * FROM (
                    SELECT m.*,
                        (SELECT COUNT(*) FROM canvas_branches cb
                         WHERE cb.fork_from_message_id = m.id) as has_branches
                    FROM messages m
                    WHERE m.session_id = ?
                    ORDER BY m.timestamp DESC
                    LIMIT ?
                ) sub ORDER BY sub.timestamp ASC
                """
            return try Message.fetchAll(db, sql: sql, arguments: [sessionId, limit])
        }
    }

    /// Get a page of messages older than the given message ID.
    /// Used for pagination — returns up to `limit` messages in chronological order.
    func getMessagesBefore(sessionId: String, beforeMessageId: String, limit: Int) throws -> [Message] {
        try db.read { db in
            let sql = """
                SELECT * FROM (
                    SELECT m.*,
                        (SELECT COUNT(*) FROM canvas_branches cb
                         WHERE cb.fork_from_message_id = m.id) as has_branches
                    FROM messages m
                    WHERE m.session_id = ? AND m.id < ?
                    ORDER BY m.timestamp DESC
                    LIMIT ?
                ) sub ORDER BY sub.timestamp ASC
                """
            return try Message.fetchAll(db, sql: sql, arguments: [sessionId, beforeMessageId, limit])
        }
    }

    /// Get messages up to (and including) a specific message ID.
    /// Used for building fork context.
    func getMessagesUpTo(sessionId: String, messageId: String, limit: Int? = nil) throws -> [Message] {
        try db.read { db in
            var sql = """
                SELECT m.*, 0 as has_branches
                FROM messages m
                WHERE m.session_id = ? AND m.id <= ?
                ORDER BY m.timestamp ASC
                """
            if let limit {
                // Take only the last N messages up to the fork point
                sql = """
                    SELECT * FROM (
                        SELECT m.*, 0 as has_branches
                        FROM messages m
                        WHERE m.session_id = ? AND m.id <= ?
                        ORDER BY m.timestamp DESC
                        LIMIT ?
                    ) sub ORDER BY sub.timestamp ASC
                    """
                return try Message.fetchAll(db, sql: sql, arguments: [sessionId, messageId, limit])
            }
            return try Message.fetchAll(db, sql: sql, arguments: [sessionId, messageId])
        }
    }

    // MARK: - Write

    /// Ensure a session row exists before inserting messages.
    /// Guards against FK constraint failures when branches outlive their session rows
    /// (e.g. DB migration, cortana-core session created outside World Tree).
    func ensureSession(sessionId: String, workingDirectory: String) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO sessions (id, terminal_id, working_directory, description, started_at)
                    VALUES (?, 'canvas', ?, 'World Tree session', datetime('now'))
                    """,
                arguments: [sessionId, workingDirectory]
            )
        }
    }

    /// Send a message (user or assistant) to a session.
    /// INSERT matches cortana-core's pattern for hook compatibility.
    /// Also touches canvas_trees.updated_at so the sidebar sorts by last activity.
    func sendMessage(sessionId: String, role: MessageRole, content: String) throws -> Message {
        try db.write { db in
            let message = try Message.insert(db: db, sessionId: sessionId, role: role, content: content)
            try db.execute(
                sql: """
                    UPDATE canvas_trees SET updated_at = datetime('now')
                    WHERE id = (SELECT tree_id FROM canvas_branches WHERE session_id = ? LIMIT 1)
                    """,
                arguments: [sessionId]
            )
            return message
        }
    }

    /// Async version of sendMessage — writes off the main thread.
    /// Use at the end of streaming to avoid blocking UI during the final persist.
    func sendMessageAsync(sessionId: String, role: MessageRole, content: String) async throws -> Message {
        try await DatabaseManager.shared.asyncWrite { db in
            let message = try Message.insert(db: db, sessionId: sessionId, role: role, content: content)
            try db.execute(
                sql: """
                    UPDATE canvas_trees SET updated_at = datetime('now')
                    WHERE id = (SELECT tree_id FROM canvas_branches WHERE session_id = ? LIMIT 1)
                    """,
                arguments: [sessionId]
            )
            return message
        }
    }

    // MARK: - Copy Messages (for branch-on-edit)

    /// Copy messages from source session up to (not including) a given message ID.
    /// Returns the number of messages copied.
    func copyMessages(from sourceSessionId: String, upTo messageId: String, to targetSessionId: String) throws -> Int {
        try db.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT role, content FROM messages
                    WHERE session_id = ? AND id < ?
                    ORDER BY timestamp ASC
                    """,
                arguments: [sourceSessionId, messageId]
            )
            let validRoles: Set<String> = ["user", "assistant", "system"]
            for row in rows {
                let role: String = row["role"]
                let content: String = row["content"]
                guard validRoles.contains(role) else {
                    wtLog("[MessageStore] copyMessages: skipping row with invalid role '\(role)' in session \(sourceSessionId)")
                    continue
                }
                try db.execute(
                    sql: """
                        INSERT INTO messages (session_id, role, content, timestamp)
                        VALUES (?, ?, ?, datetime('now'))
                        """,
                    arguments: [targetSessionId, role, content]
                )
            }
            return rows.count
        }
    }

    // MARK: - Search

    /// Search messages within a specific session using the existing FTS5 index.
    /// Falls back to LIKE if FTS fails.
    func searchMessages(query: String, sessionId: String, limit: Int = 20) throws -> [Message] {
        try db.read { db in
            do {
                let sql = """
                    SELECT m.*, 0 as has_branches
                    FROM messages m
                    JOIN messages_fts ON messages_fts.rowid = m.id
                    WHERE messages_fts MATCH ? AND m.session_id = ?
                    ORDER BY rank
                    LIMIT ?
                    """
                return try Message.fetchAll(db, sql: sql, arguments: [query, sessionId, limit])
            } catch {
                let sql = """
                    SELECT m.*, 0 as has_branches
                    FROM messages m
                    WHERE m.content LIKE ? AND m.session_id = ?
                    ORDER BY m.timestamp DESC
                    LIMIT ?
                    """
                return try Message.fetchAll(db, sql: sql, arguments: ["%\(query)%", sessionId, limit])
            }
        }
    }

    /// Search messages using the existing FTS5 index.
    /// Falls back to LIKE if FTS fails (matching cortana-core behavior).
    func searchMessages(query: String, limit: Int = 50) throws -> [Message] {
        try db.read { db in
            // Try FTS5 first
            do {
                let sql = """
                    SELECT m.*, 0 as has_branches
                    FROM messages m
                    JOIN messages_fts ON messages_fts.rowid = m.id
                    WHERE messages_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """
                return try Message.fetchAll(db, sql: sql, arguments: [query, limit])
            } catch {
                // FTS failed, fall back to LIKE
                let sql = """
                    SELECT m.*, 0 as has_branches
                    FROM messages m
                    WHERE m.content LIKE ?
                    ORDER BY m.timestamp DESC
                    LIMIT ?
                    """
                return try Message.fetchAll(db, sql: sql, arguments: ["%\(query)%", limit])
            }
        }
    }

    // MARK: - Cross-Session Search

    /// Search across all FTS indexes: messages, knowledge, conversation archives, graph nodes.
    /// Returns unified results sorted by relevance.
    func searchAcrossAll(query: String, limit: Int = 40) throws -> [GlobalSearchResult] {
        try db.read { db in
            var results: [GlobalSearchResult] = []
            let perSource = max(limit / 4, 10)

            // 1. Messages FTS
            do {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT m.id, m.session_id, m.content, m.role, m.timestamp,
                           s.working_directory
                    FROM messages m
                    JOIN messages_fts ON messages_fts.rowid = m.id
                    LEFT JOIN sessions s ON s.id = m.session_id
                    WHERE messages_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """, arguments: [query, perSource])
                for row in rows {
                    let content: String = row["content"] ?? ""
                    let wd: String = row["working_directory"] ?? ""
                    results.append(GlobalSearchResult(
                        id: "msg-\(row["id"] as Int64)",
                        source: .message,
                        title: row["role"] as String? ?? "message",
                        snippet: String(content.prefix(200)),
                        project: Self.extractProject(from: wd),
                        timestamp: Self.parseTimestamp(row["timestamp"]),
                        sessionId: row["session_id"] as String?
                    ))
                }
            } catch {
                wtLog("[GlobalSearch] messages FTS failed: \(error)")
            }

            // Batch-resolve session IDs → canvas_branches for message results
            let msgSessionIds = results.filter { $0.source == .message }.compactMap(\.sessionId)
            if !msgSessionIds.isEmpty {
                let placeholders = msgSessionIds.map { _ in "?" }.joined(separator: ", ")
                if let branchRows = try? Row.fetchAll(db, sql: """
                    SELECT session_id, id, tree_id FROM canvas_branches
                    WHERE session_id IN (\(placeholders))
                    """, arguments: StatementArguments(msgSessionIds)) {
                    let branchMap = Dictionary(uniqueKeysWithValues: branchRows.compactMap { row -> (String, (String, String))? in
                        guard let sid: String = row["session_id"],
                              let bid: String = row["id"],
                              let tid: String = row["tree_id"] else { return nil }
                        return (sid, (bid, tid))
                    })
                    results = results.map { r in
                        guard r.source == .message, let sid = r.sessionId, let (bid, tid) = branchMap[sid] else { return r }
                        var updated = r
                        updated.branchId = bid
                        updated.treeId = tid
                        return updated
                    }
                }
            }

            // 2. Knowledge FTS
            let hasKnowledge = (try? Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='knowledge_fts'
                """)) ?? false

            if hasKnowledge {
                do {
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT k.id, k.title, k.content, k.type, k.project, k.created_at
                        FROM knowledge k
                        JOIN knowledge_fts ON knowledge_fts.rowid = k.rowid
                        WHERE knowledge_fts MATCH ?
                        ORDER BY rank
                        LIMIT ?
                        """, arguments: [query, perSource])
                    for row in rows {
                        let content: String = row["content"] ?? ""
                        results.append(GlobalSearchResult(
                            id: "kb-\(row["id"] as String)",
                            source: .knowledge,
                            title: row["title"] as String? ?? "knowledge",
                            snippet: String(content.prefix(200)),
                            project: row["project"],
                            timestamp: Self.parseTimestamp(row["created_at"])
                        ))
                    }
                } catch {
                    wtLog("[GlobalSearch] knowledge FTS failed: \(error)")
                }
            }

            // 3. Conversation archive FTS
            let hasArchive = (try? Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='conversation_archive_fts'
                """)) ?? false

            if hasArchive {
                do {
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT ca.session_id, ca.project, ca.compressed_summary,
                               ca.message_count, ca.archived_at
                        FROM conversation_archive ca
                        JOIN conversation_archive_fts ON conversation_archive_fts.rowid = ca.rowid
                        WHERE conversation_archive_fts MATCH ?
                        ORDER BY rank
                        LIMIT ?
                        """, arguments: [query, perSource])
                    for row in rows {
                        let summary: String = row["compressed_summary"] ?? ""
                        results.append(GlobalSearchResult(
                            id: "archive-\(row["session_id"] as String)",
                            source: .archive,
                            title: "Session (\(row["message_count"] as Int? ?? 0) msgs)",
                            snippet: String(summary.prefix(200)),
                            project: row["project"],
                            timestamp: Self.parseTimestamp(row["archived_at"])
                        ))
                    }
                } catch {
                    wtLog("[GlobalSearch] archive FTS failed: \(error)")
                }
            }

            // 4. Graph nodes FTS
            let hasGraph = (try? Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='cg_nodes_fts'
                """)) ?? false

            if hasGraph {
                do {
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT n.id, n.label, n.content, n.type, n.project
                        FROM cg_nodes n
                        JOIN cg_nodes_fts ON cg_nodes_fts.rowid = n.rowid
                        WHERE cg_nodes_fts MATCH ?
                        LIMIT ?
                        """, arguments: [query, perSource])
                    for row in rows {
                        let content: String = row["content"] ?? ""
                        results.append(GlobalSearchResult(
                            id: "graph-\(row["id"] as String)",
                            source: .graph,
                            title: row["label"] as String? ?? "node",
                            snippet: String(content.prefix(200)),
                            project: row["project"] as String?,
                            timestamp: nil
                        ))
                    }
                } catch {
                    wtLog("[GlobalSearch] graph FTS failed: \(error)")
                }
            }

            // Sort by timestamp descending (nil last)
            results.sort { a, b in
                switch (a.timestamp, b.timestamp) {
                case let (ta?, tb?): return ta > tb
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return false
                }
            }

            return Array(results.prefix(limit))
        }
    }

    nonisolated private static func extractProject(from workingDirectory: String) -> String? {
        let parts = workingDirectory.split(separator: "/")
        for (i, part) in parts.enumerated() {
            if (part == "Development" || part == "development") && i + 1 < parts.count {
                return String(parts[i + 1])
            }
        }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let sqlFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    nonisolated private static func parseTimestamp(_ value: DatabaseValue?) -> Date? {
        guard let value, let str = String.fromDatabaseValue(value) else { return nil }
        if let date = isoFormatter.date(from: str) { return date }
        if let date = sqlFormatter.date(from: str) { return date }
        wtLog("[MessageStore] WARNING: Failed to parse timestamp '\(str)' — skipping result")
        return nil
    }

    /// Get the working directory for a session
    func getSessionWorkingDirectory(sessionId: String) throws -> String? {
        try db.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT working_directory FROM sessions WHERE id = ?",
                arguments: [sessionId]
            )
        }
    }

    // MARK: - Update

    /// Update the content of an existing message in-place.
    func updateMessageContent(id: String, content: String) {
        do {
            try db.write { db in
                try db.execute(
                    sql: "UPDATE messages SET content = ? WHERE id = ?",
                    arguments: [content, id]
                )
            }
        } catch {
            wtLog("[MessageStore] Failed to update message \(id): \(error)")
        }
    }

    /// Get the summary for a session (from existing summaries table)
    func getSessionSummary(sessionId: String) throws -> String? {
        try db.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT summary FROM summaries WHERE session_id = ? ORDER BY created_at DESC LIMIT 1",
                arguments: [sessionId]
            )
        }
    }
}
