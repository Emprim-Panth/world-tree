import Foundation
import GRDB

enum MessageRole: String, Codable, DatabaseValueConvertible {
    case user
    case assistant
    case system
}

/// Wraps the existing `messages` table from cortana-core.
/// Canvas reads and writes these using the exact same schema.
struct Message: Identifiable, Equatable, Hashable {
    let id: Int
    let sessionId: String
    let role: MessageRole
    let content: String
    let timestamp: Date

    /// Computed at query time: whether any branch forks from this message
    var hasBranches: Bool = false
}

// MARK: - GRDB Conformance

extension Message: FetchableRecord {
    init(row: Row) {
        id = row["id"]
        sessionId = row["session_id"]
        role = MessageRole(rawValue: row["role"] as String) ?? .system
        content = row["content"]
        timestamp = row["timestamp"] as? Date ?? Date()
        hasBranches = (row["has_branches"] as? Int ?? 0) > 0
    }
}

extension Message: TableRecord {
    static let databaseTableName = "messages"
}

// MARK: - Insert (matches cortana-core pattern exactly)

extension Message {
    /// Creates a new message in the existing messages table.
    /// Matches the INSERT pattern from cortana-core/src/memory/index.ts
    static func insert(
        db: Database,
        sessionId: String,
        role: MessageRole,
        content: String
    ) throws -> Message {
        try db.execute(
            sql: """
                INSERT INTO messages (session_id, role, content, timestamp)
                VALUES (?, ?, ?, datetime('now'))
                """,
            arguments: [sessionId, role.rawValue, content]
        )
        let id = Int(db.lastInsertedRowID)
        return Message(
            id: id,
            sessionId: sessionId,
            role: role,
            content: content,
            timestamp: Date()
        )
    }
}
