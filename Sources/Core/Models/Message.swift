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
    let id: String  // Gateway uses TEXT PRIMARY KEY
    let sessionId: String
    let role: MessageRole
    let content: String
    let createdAt: Date  // Table column is created_at, not timestamp

    /// Computed at query time: whether any branch forks from this message
    var hasBranches: Bool = false

    /// Compatibility alias for timestamp
    var timestamp: Date { createdAt }
}

// MARK: - GRDB Conformance

extension Message: FetchableRecord {
    init(row: Row) {
        id = row["id"]
        sessionId = row["session_id"]
        role = MessageRole(rawValue: row["role"] as String) ?? .system
        content = row["content"]

        // Read created_at as INTEGER (Unix timestamp in ms) and convert to Date
        if let timestampMs = row["created_at"] as? Int64 {
            createdAt = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
        } else {
            createdAt = Date()
        }

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
        let id = String(db.lastInsertedRowID)
        return Message(
            id: id,
            sessionId: sessionId,
            role: role,
            content: content,
            createdAt: Date()
        )
    }
}
