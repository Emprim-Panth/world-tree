import Foundation

// MARK: - Request Types

struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: [SystemBlock]
    let tools: [ToolSchema]
    let messages: [APIMessage]
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system, tools, messages, stream
    }
}

struct SystemBlock: Codable {
    let type: String
    let text: String
    var cacheControl: CacheControl?

    init(text: String, cached: Bool = false) {
        self.type = "text"
        self.text = text
        self.cacheControl = cached ? CacheControl(type: "ephemeral") : nil
    }

    enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }

    // Custom encoding: omit cache_control when nil (Anthropic API rejects null)
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(text, forKey: .text)
        if let cacheControl {
            try container.encode(cacheControl, forKey: .cacheControl)
        }
    }
}

struct CacheControl: Codable {
    let type: String
}

struct ToolSchema: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
    var cacheControl: CacheControl?

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
        case cacheControl = "cache_control"
    }

    // Custom encoding: omit cache_control when nil (Anthropic API rejects null)
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        if let cacheControl {
            try container.encode(cacheControl, forKey: .cacheControl)
        }
    }
}

struct JSONSchema: Encodable {
    let type: String
    let properties: [String: PropertySchema]
    let required: [String]
}

struct PropertySchema: Encodable {
    let type: String
    let description: String
    var enumValues: [String]?

    init(type: String, description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }

    enum CodingKeys: String, CodingKey {
        case type, description
        case enumValues = "enum"
    }

    // Custom encoding: omit enum when nil (Anthropic API rejects null)
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(description, forKey: .description)
        if let enumValues {
            try container.encode(enumValues, forKey: .enumValues)
        }
    }
}

// MARK: - API Message Types

struct APIMessage: Codable {
    let role: String
    let content: [ContentBlock]
}

/// A content block in an API message — text, tool_use, or tool_result.
/// Uses a `type` discriminator for Codable.
enum ContentBlock: Codable {
    case text(String)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)

    struct ToolUseBlock: Codable {
        let id: String
        let name: String
        let input: [String: AnyCodable]
    }

    struct ToolResultBlock: Codable {
        let toolUseId: String
        let content: String
        var isError: Bool

        enum CodingKeys: String, CodingKey {
            case toolUseId = "tool_use_id"
            case content
            case isError = "is_error"
        }

        // Only encode is_error when true (omit false to keep payload clean)
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(toolUseId, forKey: .toolUseId)
            try container.encode(content, forKey: .content)
            if isError {
                try container.encode(isError, forKey: .isError)
            }
        }
    }

    // MARK: Custom Codable

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let full = try TextBlockFull(from: decoder)
            self = .text(full.text)
        case "tool_use":
            let block = try ToolUseBlock(from: decoder)
            self = .toolUse(block)
        case "tool_result":
            let block = try ToolResultBlock(from: decoder)
            self = .toolResult(block)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown content block type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            var textContainer = encoder.container(keyedBy: TextCodingKeys.self)
            try textContainer.encode(text, forKey: .text)
        case .toolUse(let block):
            try container.encode("tool_use", forKey: .type)
            try block.encode(to: encoder)
        case .toolResult(let block):
            try container.encode("tool_result", forKey: .type)
            try block.encode(to: encoder)
        }
    }

    private enum TextCodingKeys: String, CodingKey {
        case text
    }

    private struct TextBlockFull: Decodable {
        let text: String
    }

    // MARK: Helpers

    var textContent: String? {
        if case .text(let t) = self { return t }
        return nil
    }

    var toolUseContent: ToolUseBlock? {
        if case .toolUse(let t) = self { return t }
        return nil
    }
}

// MARK: - Streaming SSE Types

enum SSEEvent {
    case messageStart(MessageStartPayload)
    case contentBlockStart(ContentBlockStartPayload)
    case contentBlockDelta(ContentBlockDeltaPayload)
    case contentBlockStop(index: Int)
    case messageDelta(MessageDeltaPayload)
    case messageStop
    case ping
    case error(APIError)
}

struct MessageStartPayload: Decodable {
    let message: MessageMeta
}

struct MessageMeta: Decodable {
    let id: String
    let model: String
    let usage: TokenUsage
}

struct TokenUsage: Codable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    static let zero = TokenUsage(inputTokens: 0, outputTokens: 0)

    mutating func add(_ other: TokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        if let c = other.cacheCreationInputTokens {
            cacheCreationInputTokens = (cacheCreationInputTokens ?? 0) + c
        }
        if let r = other.cacheReadInputTokens {
            cacheReadInputTokens = (cacheReadInputTokens ?? 0) + r
        }
    }
}

struct ContentBlockStartPayload: Decodable {
    let index: Int
    let contentBlock: ContentBlockMeta

    enum CodingKeys: String, CodingKey {
        case index
        case contentBlock = "content_block"
    }
}

struct ContentBlockMeta: Decodable {
    let type: String
    let id: String?
    let name: String?
    let text: String?
}

struct ContentBlockDeltaPayload: Decodable {
    let index: Int
    let delta: DeltaContent
}

enum DeltaContent: Decodable {
    case textDelta(String)
    case inputJsonDelta(String)

    private enum CodingKeys: String, CodingKey {
        case type, text
        case partialJson = "partial_json"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text_delta":
            let text = try container.decode(String.self, forKey: .text)
            self = .textDelta(text)
        case "input_json_delta":
            let json = try container.decode(String.self, forKey: .partialJson)
            self = .inputJsonDelta(json)
        default:
            self = .textDelta("")
        }
    }
}

struct MessageDeltaPayload: Decodable {
    let delta: MessageDeltaInfo
    let usage: OutputUsage?
}

struct MessageDeltaInfo: Decodable {
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case stopReason = "stop_reason"
    }
}

struct OutputUsage: Decodable {
    let outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case outputTokens = "output_tokens"
    }
}

struct APIError: Decodable {
    let type: String
    let error: ErrorDetail?
    let message: String?

    struct ErrorDetail: Decodable {
        let type: String
        let message: String
    }

    /// Best-effort error message extraction
    var errorMessage: String {
        error?.message ?? message ?? "Unknown API error"
    }
}

// MARK: - Session Token Tracking

struct SessionTokenUsage: Codable {
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var cacheHitTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var turnCount: Int = 0

    mutating func record(_ usage: TokenUsage) {
        totalInputTokens += usage.inputTokens
        totalOutputTokens += usage.outputTokens
        cacheHitTokens += usage.cacheReadInputTokens ?? 0
        cacheCreationTokens += usage.cacheCreationInputTokens ?? 0
        turnCount += 1
    }
}

// MARK: - Client Error Types

enum AnthropicClientError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case httpError(status: Int, body: String)
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded
    case streamingError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No ANTHROPIC_API_KEY found in environment"
        case .invalidResponse: return "Invalid response from Anthropic API"
        case .httpError(let status, let body): return "HTTP \(status): \(body.prefix(200))"
        case .rateLimited(let after):
            if let after { return "Rate limited. Retry after \(Int(after))s" }
            return "Rate limited"
        case .overloaded: return "Anthropic API is overloaded. Try again shortly."
        case .streamingError(let msg): return "Streaming error: \(msg)"
        }
    }
}
