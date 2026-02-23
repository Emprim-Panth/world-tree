import Foundation

enum MessageParser {
    /// Decode a raw WebSocket text frame into a typed ServerEvent.
    /// Uses convertFromSnakeCase to match the server's convertToSnakeCase encoding.
    static func parse(_ text: String) -> ServerEvent? {
        guard let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(ServerEvent.self, from: data)
    }

    /// Encode a client command to a JSON string for sending over WebSocket.
    /// Emits the WSMessage envelope: { "type": "...", "payload": { ... } }
    static func encode(_ command: ClientCommand) -> String? {
        var dict: [String: Any] = ["type": command.type]
        if let payload = command.payload {
            dict["payload"] = payload
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Server → Client

/// Parsed representation of a server WebSocket event.
///
/// The server sends the WSMessage envelope: { "type": "...", "id": "...", "payload": { ... } }
/// Event type names match WSServerMessageType in WebSocketProtocol.swift.
struct ServerEvent: Decodable {
    let type: String

    // trees_list payload
    var trees: [TreeSummary]?

    // branches_list payload
    var branches: [BranchSummary]?

    // messages_list payload
    var messages: [Message]?

    // token payload
    var token: String?
    var tokenIndex: Int?

    // tool_status payload (status: "started" | "completed" | "error")
    var toolName: String?
    var toolStatus: String?

    // message_complete payload
    var messageId: String?
    var messageRole: String?
    var messageContent: String?

    // error payload
    var errorMessage: String?

    private enum EnvelopeKeys: String, CodingKey {
        case type
        case payload
    }

    private enum PayloadKeys: String, CodingKey {
        // trees_list
        case trees
        // branches_list
        case branches
        // messages_list
        case messages
        // token
        case token
        case index
        // tool_status
        case tool
        case status
        // message_complete
        case messageId
        case role
        case content
        // error
        case message
    }

    init(from decoder: Decoder) throws {
        let env = try decoder.container(keyedBy: EnvelopeKeys.self)
        type = try env.decode(String.self, forKey: .type)

        guard let payload = try? env.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload) else {
            return
        }

        switch type {
        case "trees_list":
            trees = try? payload.decode([TreeSummary].self, forKey: .trees)

        case "branches_list":
            branches = try? payload.decode([BranchSummary].self, forKey: .branches)

        case "messages_list":
            messages = try? payload.decode([Message].self, forKey: .messages)

        case "token":
            token = try? payload.decode(String.self, forKey: .token)
            tokenIndex = try? payload.decode(Int.self, forKey: .index)

        case "tool_status":
            toolName = try? payload.decode(String.self, forKey: .tool)
            toolStatus = try? payload.decode(String.self, forKey: .status)

        case "message_complete":
            messageId = try? payload.decode(String.self, forKey: .messageId)
            messageRole = try? payload.decode(String.self, forKey: .role)
            messageContent = try? payload.decode(String.self, forKey: .content)

        case "error":
            errorMessage = try? payload.decode(String.self, forKey: .message)

        default:
            break
        }
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

/// Client → Server WebSocket command.
/// Encoded as WSMessage envelope: { "type": "...", "payload": { ... } }
/// Payload keys use camelCase to match server's WSPayload re-decode (default JSONDecoder).
struct ClientCommand {
    let type: String
    /// Payload values — must be JSON-serializable (String, Int, Bool, nested dicts/arrays).
    let payload: [String: Any]?

    static func listTrees() -> ClientCommand {
        ClientCommand(type: "list_trees", payload: nil)
    }

    static func listBranches(treeId: String) -> ClientCommand {
        ClientCommand(type: "list_branches", payload: ["treeId": treeId])
    }

    /// Renamed from load_history → get_messages to match server WSClientMessageType.
    static func loadHistory(branchId: String) -> ClientCommand {
        ClientCommand(type: "get_messages", payload: ["branchId": branchId, "limit": 50])
    }

    /// Subscribe to a branch before sending messages (required by server BR-003).
    static func subscribe(treeId: String, branchId: String) -> ClientCommand {
        ClientCommand(type: "subscribe", payload: ["treeId": treeId, "branchId": branchId])
    }

    static func sendMessage(branchId: String, content: String) -> ClientCommand {
        ClientCommand(type: "send_message", payload: ["branchId": branchId, "content": content])
    }

    static func cancelStream(branchId: String) -> ClientCommand {
        ClientCommand(type: "cancel_stream", payload: ["branchId": branchId])
    }

    static func createTree(name: String, project: String? = nil) -> ClientCommand {
        var payload: [String: Any] = ["name": name]
        if let project { payload["project"] = project }
        return ClientCommand(type: "create_tree", payload: payload)
    }

    static func createBranch(
        treeId: String,
        fromMessageId: String? = nil,
        parentBranchId: String? = nil,
        title: String? = nil
    ) -> ClientCommand {
        var payload: [String: Any] = ["treeId": treeId]
        if let title { payload["title"] = title }
        if let fromMessageId { payload["fromMessageId"] = fromMessageId }
        if let parentBranchId { payload["parentBranchId"] = parentBranchId }
        return ClientCommand(type: "create_branch", payload: payload)
    }
}
