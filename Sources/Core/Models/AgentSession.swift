import Foundation
import GRDB

// MARK: - Agent Session Status

enum AgentSessionStatus: String, Codable, DatabaseValueConvertible {
    case starting
    case thinking
    case writing
    case toolUse = "tool_use"
    case waiting
    case stuck
    case idle
    case completed
    case failed
    case interrupted
}

// MARK: - Agent Session Model

/// A tracked agent session — interactive, dispatch, heartbeat, or event-triggered.
/// Maps to the `agent_sessions` table for real-time observability in the Command Center.
struct AgentSession: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "agent_sessions"

    var id: String
    var agentName: String?
    var project: String
    var workingDirectory: String
    var source: String              // 'interactive', 'dispatch', 'heartbeat', 'event_rule'

    // Lifecycle
    var status: AgentSessionStatus
    var startedAt: Date?
    var completedAt: Date?
    var lastActivityAt: Date?

    // Current work
    var currentTask: String?
    var currentFile: String?
    var currentTool: String?

    // Health signals
    var errorCount: Int
    var retryCount: Int
    var consecutiveErrors: Int

    // Token tracking
    var tokensIn: Int
    var tokensOut: Int
    var contextUsed: Int
    var contextMax: Int

    // Output
    var filesChanged: String        // JSON array string
    var exitReason: String?

    // Dispatch linkage
    var dispatchId: String?

    enum CodingKeys: String, CodingKey {
        case id, project, source, status
        case agentName = "agent_name"
        case workingDirectory = "working_directory"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case lastActivityAt = "last_activity_at"
        case currentTask = "current_task"
        case currentFile = "current_file"
        case currentTool = "current_tool"
        case errorCount = "error_count"
        case retryCount = "retry_count"
        case consecutiveErrors = "consecutive_errors"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case contextUsed = "context_used"
        case contextMax = "context_max"
        case filesChanged = "files_changed"
        case exitReason = "exit_reason"
        case dispatchId = "dispatch_id"
    }

    init(
        id: String = UUID().uuidString,
        agentName: String? = nil,
        project: String,
        workingDirectory: String,
        source: String = "interactive",
        status: AgentSessionStatus = .starting,
        startedAt: Date? = Date(),
        completedAt: Date? = nil,
        lastActivityAt: Date? = Date(),
        currentTask: String? = nil,
        currentFile: String? = nil,
        currentTool: String? = nil,
        errorCount: Int = 0,
        retryCount: Int = 0,
        consecutiveErrors: Int = 0,
        tokensIn: Int = 0,
        tokensOut: Int = 0,
        contextUsed: Int = 0,
        contextMax: Int = 200_000,
        filesChanged: String = "[]",
        exitReason: String? = nil,
        dispatchId: String? = nil
    ) {
        self.id = id
        self.agentName = agentName
        self.project = project
        self.workingDirectory = workingDirectory
        self.source = source
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.lastActivityAt = lastActivityAt
        self.currentTask = currentTask
        self.currentFile = currentFile
        self.currentTool = currentTool
        self.errorCount = errorCount
        self.retryCount = retryCount
        self.consecutiveErrors = consecutiveErrors
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.contextUsed = contextUsed
        self.contextMax = contextMax
        self.filesChanged = filesChanged
        self.exitReason = exitReason
        self.dispatchId = dispatchId
    }

    // MARK: - Computed

    /// Decode the JSON files_changed array into Swift strings.
    var filesChangedArray: [String] {
        guard let data = filesChanged.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return array
    }

    /// Context window usage as a percentage (0.0–1.0).
    var contextPercentage: Double {
        guard contextMax > 0 else { return 0 }
        return Double(contextUsed) / Double(contextMax)
    }

    /// Total tokens consumed (input + output).
    var totalTokens: Int {
        tokensIn + tokensOut
    }

    /// Session duration from start to completion (or now if still active).
    var duration: TimeInterval? {
        guard let start = startedAt else { return nil }
        let end = completedAt ?? Date()
        return end.timeIntervalSince(start)
    }

    /// Whether this session is still running.
    var isActive: Bool {
        switch status {
        case .completed, .failed, .interrupted:
            return false
        default:
            return true
        }
    }

    /// Formatted duration string.
    var durationString: String? {
        guard let d = duration else { return nil }
        if d < 60 { return "\(Int(d))s" }
        if d < 3600 { return "\(Int(d / 60))m" }
        return "\(Int(d / 3600))h \(Int((d.truncatingRemainder(dividingBy: 3600)) / 60))m"
    }
}
