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
    func getMessagesUpTo(sessionId: String, messageId: Int, limit: Int? = nil) throws -> [Message] {
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

    /// Send a message (user or assistant) to a session.
    /// INSERT matches cortana-core's pattern for hook compatibility.
    func sendMessage(sessionId: String, role: MessageRole, content: String) throws -> Message {
        try db.write { db in
            try Message.insert(db: db, sessionId: sessionId, role: role, content: content)
        }
    }

    // MARK: - Search

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
