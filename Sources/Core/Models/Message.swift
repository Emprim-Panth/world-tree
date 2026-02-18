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
        // id is INTEGER in database, convert to String
        if let intId = row["id"] as? Int64 {
            id = String(intId)
        } else if let stringId = row["id"] as? String {
            id = stringId
        } else {
            id = "0"
        }

        sessionId = row["session_id"]
        role = MessageRole(rawValue: row["role"] as String) ?? .system
        content = row["content"]

        // Read timestamp as DATETIME text and convert to Date
        if let timestampStr = row["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
            if let date = formatter.date(from: timestampStr.replacingOccurrences(of: " ", with: "T") + "Z") {
                createdAt = date
            } else {
                // Fallback: try basic SQLite datetime format
                let sqlFormatter = DateFormatter()
                sqlFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                sqlFormatter.timeZone = TimeZone(secondsFromGMT: 0)
                createdAt = sqlFormatter.date(from: timestampStr) ?? Date()
            }
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
