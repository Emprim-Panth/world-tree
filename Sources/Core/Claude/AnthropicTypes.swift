import Foundation

// MARK: - Request Types

/// Extended thinking configuration. When set, Claude reasons internally before responding.
///
/// Two modes:
/// - `enabled`: Manual budget — you specify exact budget_tokens. Required for older models.
/// - `adaptive`: Model decides when and how deeply to think. Preferred for Opus 4.6+.
///   Faster on simple queries, deeper on complex ones. No budget_tokens needed.
struct ThinkingConfig: Encodable {
    let type: String
    let budgetTokens: Int?

    /// Adaptive thinking — model decides when/how much to think. Preferred for Opus 4.6+.
    static func adaptive() -> ThinkingConfig {
        ThinkingConfig(type: "adaptive", budgetTokens: nil)
    }

    /// Manual budget — explicit token budget for thinking. Use for Sonnet or when you need control.
    static func enabled(budgetTokens: Int) -> ThinkingConfig {
        ThinkingConfig(type: "enabled", budgetTokens: budgetTokens)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if let budgetTokens {
            try container.encode(budgetTokens, forKey: .budgetTokens)
        }
    }
}

/// Effort level for thinking depth control.
/// Low = faster/cheaper, Max = deepest reasoning.
enum EffortLevel: String, Encodable {
    case low, medium, high, max
}

struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: [SystemBlock]
    let tools: [ToolSchema]
    let messages: [APIMessage]
    let stream: Bool
    let thinking: ThinkingConfig?
    /// Controls how much effort the model puts into its response.
    /// Nil uses the API default (varies by model). Low = fast, Max = deepest reasoning.
    var effort: EffortLevel?

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system, tools, messages, stream, thinking
        case outputConfig = "output_config"
    }

    // Custom encode: omit thinking/effort when nil
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(system, forKey: .system)
        try container.encode(tools, forKey: .tools)
        try container.encode(messages, forKey: .messages)
        try container.encode(stream, forKey: .stream)
        if let thinking {
            try container.encode(thinking, forKey: .thinking)
        }
        if let effort {
            try container.encode(["effort": effort], forKey: .outputConfig)
        }
    }
}

struct SystemBlock: Codable {
    let type: String
    let text: String
    var cacheControl: CacheControl?

    /// Whether this block is pinned (cached). Derived from cacheControl.
    /// Use this instead of checking cacheControl != nil directly.
    var isPinned: Bool { cacheControl != nil }

    init(text: String, cached: Bool = false, longCache: Bool = false) {
        self.type = "text"
        self.text = text
        if longCache {
            self.cacheControl = .ephemeral1h
        } else if cached {
            self.cacheControl = .ephemeral
        } else {
            self.cacheControl = nil
        }
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
    /// TTL in seconds. Default 5 minutes (nil). Set to 3600 for 1-hour cache.
    /// 1-hour cache costs 2x at write time but persists across sessions.
    let ttl: Int?

    init(type: String, ttl: Int? = nil) {
        self.type = type
        self.ttl = ttl
    }

    /// Standard ephemeral cache — 5 minute TTL (API default)
    static let ephemeral = CacheControl(type: "ephemeral")

    /// Long-lived ephemeral cache — 1 hour TTL. Ideal for system prompts and tool definitions
    /// that are identical across sessions. Costs 2x at write, saves 90% on subsequent reads.
    static let ephemeral1h = CacheControl(type: "ephemeral", ttl: 3600)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if let ttl {
            try container.encode(ttl, forKey: .ttl)
        }
    }
}

struct ToolSchema: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
    var cacheControl: CacheControl?
    /// When true, constrains model output to guarantee schema-valid tool calls.
    /// Eliminates malformed JSON tool arguments via constrained decoding.
    var strict: Bool?

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
        case cacheControl = "cache_control"
        case strict
    }

    // Custom encoding: omit cache_control and strict when nil (Anthropic API rejects null)
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        if let cacheControl {
            try container.encode(cacheControl, forKey: .cacheControl)
        }
        if let strict, strict {
            try container.encode(strict, forKey: .strict)
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

/// A content block in an API message — text, image, tool_use, or tool_result.
/// Uses a `type` discriminator for Codable.
enum ContentBlock: Codable {
    case text(String)
    case image(ImageBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)

    /// Anthropic vision image block — base64-encoded image with media type.
    struct ImageBlock: Codable {
        let mediaType: String    // "image/jpeg", "image/png", "image/gif", "image/webp"
        let data: String         // base64-encoded image bytes

        enum CodingKeys: String, CodingKey {
            case type, source
        }
        enum SourceCodingKeys: String, CodingKey {
            case type, mediaType = "media_type", data
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("image", forKey: .type)
            var source = container.nestedContainer(keyedBy: SourceCodingKeys.self, forKey: .source)
            try source.encode("base64", forKey: .type)
            try source.encode(mediaType, forKey: .mediaType)
            try source.encode(data, forKey: .data)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let source = try container.nestedContainer(keyedBy: SourceCodingKeys.self, forKey: .source)
            mediaType = try source.decode(String.self, forKey: .mediaType)
            data = try source.decode(String.self, forKey: .data)
        }

        init(mediaType: String, data: String) {
            self.mediaType = mediaType
            self.data = data
        }
    }

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

        init(toolUseId: String, content: String, isError: Bool) {
            self.toolUseId = toolUseId
            self.content = content
            self.isError = isError
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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            toolUseId = try container.decode(String.self, forKey: .toolUseId)
            content = try container.decode(String.self, forKey: .content)
            isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
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
        case "image":
            let block = try ImageBlock(from: decoder)
            self = .image(block)
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
        case .image(let block):
            try block.encode(to: encoder)
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
    case thinkingDelta(String)
    case signatureDelta(String)

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, signature
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
        case "thinking_delta":
            let thinking = try container.decode(String.self, forKey: .thinking)
            self = .thinkingDelta(thinking)
        case "signature_delta":
            let signature = try container.decode(String.self, forKey: .signature)
            self = .signatureDelta(signature)
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

struct SessionTokenUsage: Codable, Sendable {
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

// MARK: - Rate Limit Info

/// Parsed from Anthropic response headers — tracks remaining capacity.
struct RateLimitInfo: Sendable {
    let requestsRemaining: Int?
    let tokensRemaining: Int?
    let requestsReset: Date?
    let tokensReset: Date?

    /// Parse rate limit headers from an HTTP response.
    static func from(_ response: HTTPURLResponse) -> RateLimitInfo {
        let isoFormatter = ISO8601DateFormatter()
        return RateLimitInfo(
            requestsRemaining: response.value(forHTTPHeaderField: "anthropic-ratelimit-requests-remaining").flatMap { Int($0) },
            tokensRemaining: response.value(forHTTPHeaderField: "anthropic-ratelimit-tokens-remaining").flatMap { Int($0) },
            requestsReset: response.value(forHTTPHeaderField: "anthropic-ratelimit-requests-reset").flatMap { isoFormatter.date(from: $0) },
            tokensReset: response.value(forHTTPHeaderField: "anthropic-ratelimit-tokens-reset").flatMap { isoFormatter.date(from: $0) }
        )
    }

    /// True if we're running low on either requests or tokens.
    var isNearLimit: Bool {
        if let r = requestsRemaining, r < 10 { return true }
        if let t = tokensRemaining, t < 50_000 { return true }
        return false
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
