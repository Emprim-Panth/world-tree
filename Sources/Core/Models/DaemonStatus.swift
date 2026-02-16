import Foundation

struct DaemonStatus: Codable {
    let pid: Int?
    let uptime: TimeInterval?
    let activeSessions: Int
    let maxConcurrent: Int
    let healthy: Bool
}

struct DaemonSession: Identifiable, Codable {
    var id: String { taskId }
    let taskId: String
    let project: String
    let model: String?
    let startedAt: Date?
    let status: String
}

/// A tmux session discovered via `tmux list-panes -a`.
/// Enriched with pane-level data for Claude session detection and context monitoring.
struct TmuxSession: Identifiable {
    var id: String { name }
    let name: String
    let windowCount: Int
    let createdAt: Date
    let isAttached: Bool
    let lastActivity: Date

    // Pane-level data (from the active pane)
    var workingDirectory: String?
    var currentCommand: String?
    var panePid: Int?

    // Claude session data (populated if Claude is running)
    var claudeSessionId: String?
    var estimatedTokens: Int?
    var pressureLevel: PressureLevel?
    var lastAutoCompact: Date?

    /// Whether this pane appears to be running a Claude CLI session.
    var isClaudeSession: Bool {
        guard let cmd = currentCommand?.lowercased() else { return false }
        return cmd.contains("claude") || claudeSessionId != nil
    }

    /// Project name inferred from working directory.
    var projectName: String? {
        guard let dir = workingDirectory else { return nil }
        return URL(fileURLWithPath: dir).lastPathComponent
    }
}

struct DaemonCommand: Codable {
    let action: String
    var message: String?
    var project: String?
    var priority: String?
    var taskId: String?

    static func dispatch(message: String, project: String, priority: String = "normal") -> DaemonCommand {
        DaemonCommand(action: "dispatch", message: message, project: project, priority: priority)
    }

    static let status = DaemonCommand(action: "status")
    static let sessions = DaemonCommand(action: "sessions")

    static func kill(taskId: String) -> DaemonCommand {
        DaemonCommand(action: "kill", taskId: taskId)
    }
}

struct DaemonResponse: Codable {
    let ok: Bool?
    let error: String?
    let taskId: String?
    let data: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case ok, error
        case taskId = "task_id"
        case data
    }
}

