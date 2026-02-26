import Foundation
import GRDB

/// A programmatic dispatch tracked by the Agent SDK provider.
/// Unlike interactive conversations (ClaudeCodeProvider), dispatches are fire-and-forget
/// with structured result collection and per-project tracking.
struct WorldTreeDispatch: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "canvas_dispatches"

    var id: String
    let project: String
    var branchId: String?
    let message: String
    var model: String?
    var status: DispatchStatus
    let workingDirectory: String
    let origin: String
    var resultText: String?
    var resultTokensIn: Int?
    var resultTokensOut: Int?
    var error: String?
    var cliSessionId: String?
    var startedAt: Date?
    var completedAt: Date?
    let createdAt: Date

    enum DispatchStatus: String, Codable, DatabaseValueConvertible {
        case queued
        case running
        case completed
        case failed
        case cancelled
        case interrupted
    }

    init(
        id: String = UUID().uuidString,
        project: String,
        branchId: String? = nil,
        message: String,
        model: String? = nil,
        status: DispatchStatus = .queued,
        workingDirectory: String,
        origin: String = "background",
        resultText: String? = nil,
        resultTokensIn: Int? = nil,
        resultTokensOut: Int? = nil,
        error: String? = nil,
        cliSessionId: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.project = project
        self.branchId = branchId
        self.message = message
        self.model = model
        self.status = status
        self.workingDirectory = workingDirectory
        self.origin = origin
        self.resultText = resultText
        self.resultTokensIn = resultTokensIn
        self.resultTokensOut = resultTokensOut
        self.error = error
        self.cliSessionId = cliSessionId
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, project, message, model, status, origin, error
        case branchId = "branch_id"
        case workingDirectory = "working_directory"
        case resultText = "result_text"
        case resultTokensIn = "result_tokens_in"
        case resultTokensOut = "result_tokens_out"
        case cliSessionId = "cli_session_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case createdAt = "created_at"
    }

    // MARK: - Computed

    var isActive: Bool {
        status == .queued || status == .running
    }

    /// Compact display string for UI
    var displayMessage: String {
        message.count > 80 ? String(message.prefix(80)) + "..." : message
    }

    /// Duration if started
    var duration: TimeInterval? {
        guard let start = startedAt else { return nil }
        let end = completedAt ?? Date()
        return end.timeIntervalSince(start)
    }

    /// Formatted duration string
    var durationString: String? {
        guard let d = duration else { return nil }
        if d < 60 { return "\(Int(d))s" }
        if d < 3600 { return "\(Int(d / 60))m" }
        return "\(Int(d / 3600))h \(Int((d.truncatingRemainder(dividingBy: 3600)) / 60))m"
    }
}
