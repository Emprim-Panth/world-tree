import Foundation

enum MessageParser {
    /// Attempts to decode a raw WebSocket text frame into a typed ServerEvent.
    static func parse(_ text: String) -> ServerEvent? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ServerEvent.self, from: data)
    }

    /// Encodes a client command to a JSON string for sending over WebSocket.
    static func encode(_ command: ClientCommand) -> String? {
        guard let data = try? JSONEncoder().encode(command) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Server → Client

struct ServerEvent: Decodable {
    let type: String
    let trees: [TreeSummary]?
    let branches: [BranchSummary]?
    let messages: [Message]?
    let token: String?
    let index: Int?
    let error: String?
    /// Tool name for tool_start / tool_end events.
    let toolName: String?
    /// Whether the tool ended with an error (tool_end only).
    let toolError: Bool?

    enum CodingKeys: String, CodingKey {
        case type, trees, branches, messages, token, index, error
        case toolName  = "tool_name"
        case toolError = "tool_error"
    }
}

// MARK: - ToolChip

/// Represents a single in-progress or completed tool call displayed inline.
struct ToolChip: Identifiable, Equatable {
    let id: UUID
    let toolName: String
    var state: ToolChipState

    enum ToolChipState: Equatable {
        case running
        case done
        case failed
    }

    static func running(_ name: String) -> ToolChip {
        ToolChip(id: UUID(), toolName: name, state: .running)
    }
}

// MARK: - Client → Server

struct ClientCommand: Encodable {
    let type: String
    let treeId: String?
    let branchId: String?
    let content: String?

    enum CodingKeys: String, CodingKey {
        case type
        case treeId = "tree_id"
        case branchId = "branch_id"
        case content
    }

    static func listTrees() -> ClientCommand {
        ClientCommand(type: "list_trees", treeId: nil, branchId: nil, content: nil)
    }

    static func listBranches(treeId: String) -> ClientCommand {
        ClientCommand(type: "list_branches", treeId: treeId, branchId: nil, content: nil)
    }

    static func loadHistory(branchId: String) -> ClientCommand {
        ClientCommand(type: "load_history", treeId: nil, branchId: branchId, content: nil)
    }

    static func sendMessage(branchId: String, content: String) -> ClientCommand {
        ClientCommand(type: "send_message", treeId: nil, branchId: branchId, content: content)
    }

    static func cancelStream(branchId: String) -> ClientCommand {
        ClientCommand(type: "cancel_stream", treeId: nil, branchId: branchId, content: nil)
    }
}
