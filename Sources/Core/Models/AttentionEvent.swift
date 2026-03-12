import Foundation
import GRDB

// MARK: - Attention Event Types

enum AttentionEventType: String, Codable, DatabaseValueConvertible {
    case permissionNeeded = "permission_needed"
    case stuck
    case errorLoop = "error_loop"
    case completed
    case contextLow = "context_low"
    case conflict
    case reviewReady = "review_ready"
}

enum AttentionSeverity: String, Codable, DatabaseValueConvertible {
    case critical
    case warning
    case info
}

// MARK: - Attention Event Model

/// An event requiring human attention — permission prompts, stuck agents, error loops, etc.
/// Maps to the `agent_attention_events` table.
struct AttentionEvent: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "agent_attention_events"

    var id: String
    var sessionId: String
    var type: AttentionEventType
    var severity: AttentionSeverity
    var message: String
    var metadata: String?           // JSON
    var acknowledged: Bool
    var createdAt: Date?
    var acknowledgedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, type, severity, message, metadata, acknowledged
        case sessionId = "session_id"
        case createdAt = "created_at"
        case acknowledgedAt = "acknowledged_at"
    }

    init(
        id: String = UUID().uuidString,
        sessionId: String,
        type: AttentionEventType,
        severity: AttentionSeverity = .info,
        message: String,
        metadata: String? = nil,
        acknowledged: Bool = false,
        createdAt: Date? = Date(),
        acknowledgedAt: Date? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.type = type
        self.severity = severity
        self.message = message
        self.metadata = metadata
        self.acknowledged = acknowledged
        self.createdAt = createdAt
        self.acknowledgedAt = acknowledgedAt
    }

    // MARK: - Computed

    var isUnacknowledged: Bool {
        !acknowledged
    }

    var isCritical: Bool {
        severity == .critical
    }
}
