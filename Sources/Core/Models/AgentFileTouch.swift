import Foundation
import GRDB

// MARK: - Agent File Touch Model

/// A record of an agent touching a file — edits, creates, deletes, reads.
/// Maps to the `agent_file_touches` table for conflict detection and activity tracking.
struct AgentFileTouch: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "agent_file_touches"

    var id: Int64?
    var sessionId: String
    var agentName: String?
    var filePath: String
    var project: String
    var action: String              // 'edit', 'create', 'delete', 'read'
    var touchedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, project, action
        case sessionId = "session_id"
        case agentName = "agent_name"
        case filePath = "file_path"
        case touchedAt = "touched_at"
    }

    init(
        id: Int64? = nil,
        sessionId: String,
        agentName: String? = nil,
        filePath: String,
        project: String,
        action: String = "edit",
        touchedAt: Date? = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.agentName = agentName
        self.filePath = filePath
        self.project = project
        self.action = action
        self.touchedAt = touchedAt
    }

    // MARK: - GRDB auto-increment support

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
