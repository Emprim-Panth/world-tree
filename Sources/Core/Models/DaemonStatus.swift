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

/// A tmux session discovered via `tmux list-sessions`.
struct TmuxSession: Identifiable {
    var id: String { name }
    let name: String
    let windowCount: Int
    let createdAt: Date
    let isAttached: Bool
    let lastActivity: Date
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

/// Lightweight type-erased Codable for daemon JSON responses
struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = dict }
        else if let array = try? container.decode([AnyCodable].self) { value = array }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as Bool: try container.encode(v)
        case let v as [String: AnyCodable]: try container.encode(v)
        case let v as [AnyCodable]: try container.encode(v)
        default: try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}
