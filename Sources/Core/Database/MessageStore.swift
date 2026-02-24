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

    /// Get messages for a session, with branch fork indicators
    func getMessages(sessionId: String, limit: Int = 500) throws -> [Message] {
        try db.read { db in
            let sql = """
                SELECT m.*,
                    (SELECT COUNT(*) FROM canvas_branches cb
                     WHERE cb.fork_from_message_id = m.id) as has_branches
                FROM messages m
                WHERE m.session_id = ?
                ORDER BY m.timestamp ASC
                LIMIT ?
                """
            return try Message.fetchAll(db, sql: sql, arguments: [sessionId, limit])
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
                    VALUES (?, 'canvas', ?, 'Canvas session', datetime('now'))
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
                    canvasLog("[MessageStore] copyMessages: skipping row with invalid role '\(role)' in session \(sourceSessionId)")
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
            canvasLog("[MessageStore] Failed to update message \(id): \(error)")
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
