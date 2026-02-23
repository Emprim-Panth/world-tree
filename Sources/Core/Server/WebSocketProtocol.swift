import Foundation

// MARK: - Message Envelope

/// Top-level WebSocket message envelope. All messages (client and server) share this shape.
struct WSMessage: Codable {
    let type: String
    let id: String?
    let payload: WSPayload?

    init(type: String, id: String? = nil, payload: WSPayload? = nil) {
        self.type = type
        self.id = id
        self.payload = payload
    }
}

/// Type-erased payload container that can hold any Codable value.
/// Uses manual encoding/decoding to act as a pass-through for known payload types.
struct WSPayload: Codable {
    private let storage: AnyCodable

    init<T: Codable>(_ value: T) {
        self.storage = AnyCodable(value)
    }

    init(from decoder: Decoder) throws {
        self.storage = try AnyCodable(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try storage.encode(to: encoder)
    }

    /// Decode the payload as a specific type.
    func decode<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(storage)
        return try JSONDecoder().decode(T.self, from: data)
    }
}


// MARK: - Client → Server Message Types

enum WSClientMessageType: String, Codable {
    case subscribe
    case unsubscribe
    case sendMessage = "send_message"
    case listTrees = "list_trees"
    case listBranches = "list_branches"
    case getMessages = "get_messages"
    case cancelStream = "cancel_stream"
    case createTree = "create_tree"
    case createBranch = "create_branch"
}

struct WSSubscribePayload: Codable {
    let treeId: String
    let branchId: String
}

struct WSSendMessagePayload: Codable {
    let branchId: String
    let content: String
}

struct WSListBranchesPayload: Codable {
    let treeId: String
}

struct WSGetMessagesPayload: Codable {
    let branchId: String
    let limit: Int?
    let before: String?
}

struct WSCancelStreamPayload: Codable {
    let branchId: String
}

struct WSCreateTreePayload: Codable {
    let name: String
    let project: String?
}

struct WSCreateBranchPayload: Codable {
    let treeId: String
    let title: String?
    /// Message ID to fork from (context snapshot up to this message).
    let fromMessageId: String?
    /// Parent branch ID — used to preserve the lineage for UI rendering.
    let parentBranchId: String?
}

// MARK: - Server → Client Message Types

enum WSServerMessageType: String, Codable {
    case token
    case messageComplete = "message_complete"
    case toolStatus = "tool_status"
    case messageAdded = "message_added"
    case treeUpdated = "tree_updated"
    case treesList = "trees_list"
    case branchesList = "branches_list"
    case messagesList = "messages_list"
    case error
}

struct WSTokenPayload: Codable {
    let branchId: String
    let sessionId: String
    let token: String
    let index: Int
}

struct WSMessageCompletePayload: Codable {
    let branchId: String
    let sessionId: String
    let messageId: String
    let role: String
    let content: String
    let tokenCount: Int
}

struct WSToolStatusPayload: Codable {
    let branchId: String
    let tool: String
    let status: String  // "started" | "completed" | "error"
    let error: String?

    init(branchId: String, tool: String, status: String, error: String? = nil) {
        self.branchId = branchId
        self.tool = tool
        self.status = status
        self.error = error
    }
}

struct WSMessageAddedPayload: Codable {
    let branchId: String
    let messageId: String
    let role: String
    let content: String
    let createdAt: String  // ISO8601
}

struct WSTreeUpdatedPayload: Codable {
    let treeId: String
    let name: String
    let updatedAt: String  // ISO8601
}

struct WSTreesListPayload: Codable {
    let trees: [WSTreeInfo]
}

struct WSTreeInfo: Codable {
    let id: String
    let name: String
    let project: String?
    let updatedAt: String
    let messageCount: Int
}

struct WSBranchesListPayload: Codable {
    let branches: [WSBranchInfo]
}

struct WSBranchInfo: Codable {
    let id: String
    let treeId: String
    let title: String?
    let status: String
    let branchType: String
    let createdAt: String
    let updatedAt: String
}

struct WSMessagesListPayload: Codable {
    let messages: [WSMessageInfo]
}

struct WSMessageInfo: Codable {
    let id: String
    let role: String
    let content: String
    let createdAt: String
}

struct WSErrorPayload: Codable {
    let code: String
    let message: String?

    init(code: String, message: String? = nil) {
        self.code = code
        self.message = message
    }
}

// MARK: - Encoding Helpers

extension WSMessage {
    /// Encode this message to a JSON string suitable for sending over WebSocket.
    func toJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode a WSMessage from a JSON string received over WebSocket.
    static func fromJSON(_ string: String) -> WSMessage? {
        guard let data = string.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(WSMessage.self, from: data)
    }
}

// MARK: - Server Message Builders

extension WSMessage {
    /// Build a token streaming event.
    static func token(branchId: String, sessionId: String, token: String, index: Int, id: String? = nil) -> WSMessage {
        WSMessage(
            type: WSServerMessageType.token.rawValue,
            id: id,
            payload: WSPayload(WSTokenPayload(branchId: branchId, sessionId: sessionId, token: token, index: index))
        )
    }

    /// Build a message-complete event.
    static func messageComplete(branchId: String, sessionId: String, messageId: String, role: String, content: String, tokenCount: Int, id: String? = nil) -> WSMessage {
        WSMessage(
            type: WSServerMessageType.messageComplete.rawValue,
            id: id,
            payload: WSPayload(WSMessageCompletePayload(branchId: branchId, sessionId: sessionId, messageId: messageId, role: role, content: content, tokenCount: tokenCount))
        )
    }

    /// Build a tool status event.
    static func toolStatus(branchId: String, tool: String, status: String, error: String? = nil) -> WSMessage {
        WSMessage(
            type: WSServerMessageType.toolStatus.rawValue,
            payload: WSPayload(WSToolStatusPayload(branchId: branchId, tool: tool, status: status, error: error))
        )
    }

    /// Build a message-added event.
    static func messageAdded(branchId: String, messageId: String, role: String, content: String, createdAt: String) -> WSMessage {
        WSMessage(
            type: WSServerMessageType.messageAdded.rawValue,
            payload: WSPayload(WSMessageAddedPayload(branchId: branchId, messageId: messageId, role: role, content: content, createdAt: createdAt))
        )
    }

    /// Build a tree-updated event.
    static func treeUpdated(treeId: String, name: String, updatedAt: String) -> WSMessage {
        WSMessage(
            type: WSServerMessageType.treeUpdated.rawValue,
            payload: WSPayload(WSTreeUpdatedPayload(treeId: treeId, name: name, updatedAt: updatedAt))
        )
    }

    /// Build a trees list response.
    static func treesList(trees: [WSTreeInfo], id: String? = nil) -> WSMessage {
        WSMessage(
            type: WSServerMessageType.treesList.rawValue,
            id: id,
            payload: WSPayload(WSTreesListPayload(trees: trees))
        )
    }

    /// Build a branches list response.
    static func branchesList(branches: [WSBranchInfo], id: String? = nil) -> WSMessage {
        WSMessage(
            type: WSServerMessageType.branchesList.rawValue,
            id: id,
            payload: WSPayload(WSBranchesListPayload(branches: branches))
        )
    }

    /// Build a messages list response.
    static func messagesList(messages: [WSMessageInfo], id: String? = nil) -> WSMessage {
        WSMessage(
            type: WSServerMessageType.messagesList.rawValue,
            id: id,
            payload: WSPayload(WSMessagesListPayload(messages: messages))
        )
    }

    /// Build an error response.
    static func error(code: String, message: String? = nil, id: String? = nil) -> WSMessage {
        WSMessage(
            type: WSServerMessageType.error.rawValue,
            id: id,
            payload: WSPayload(WSErrorPayload(code: code, message: message))
        )
    }
}
