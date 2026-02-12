import Foundation

// MARK: - Provider Protocol

/// The contract every LLM backend must fulfill.
/// All providers map their native events to `BridgeEvent` for UI consumption.
protocol LLMProvider: AnyObject {
    /// Human-readable name for UI display
    var displayName: String { get }

    /// Unique identifier for persistence (e.g. "claude-code", "anthropic-api", "ollama")
    var identifier: String { get }

    /// What this provider can do
    var capabilities: ProviderCapabilities { get }

    /// Whether a request is currently active
    var isRunning: Bool { get }

    /// Check if this provider is currently usable
    func checkHealth() async -> ProviderHealth

    /// Send a message and receive a stream of BridgeEvents.
    func send(context: ProviderSendContext) -> AsyncStream<BridgeEvent>

    /// Cancel the current in-flight request
    func cancel()
}

// MARK: - Capabilities

struct ProviderCapabilities: OptionSet, Sendable {
    let rawValue: Int

    /// Streams text token-by-token as it generates
    static let streaming       = ProviderCapabilities(rawValue: 1 << 0)
    /// Can execute tools (read files, bash, etc.)
    static let toolExecution   = ProviderCapabilities(rawValue: 1 << 1)
    /// Can resume a previous conversation
    static let sessionResume   = ProviderCapabilities(rawValue: 1 << 2)
    /// Can fork a session for branching
    static let sessionFork     = ProviderCapabilities(rawValue: 1 << 3)
    /// Supports Anthropic prompt caching
    static let promptCaching   = ProviderCapabilities(rawValue: 1 << 4)
    /// Reports token-level cost/usage data
    static let costTracking    = ProviderCapabilities(rawValue: 1 << 5)
    /// Supports model selection (sonnet, opus, haiku, etc.)
    static let modelSelection  = ProviderCapabilities(rawValue: 1 << 6)
}

// MARK: - Health

enum ProviderHealth {
    case available
    case degraded(reason: String)
    case unavailable(reason: String)

    var isUsable: Bool {
        switch self {
        case .available, .degraded: return true
        case .unavailable: return false
        }
    }

    var statusLabel: String {
        switch self {
        case .available: return "Available"
        case .degraded(let r): return "Degraded: \(r)"
        case .unavailable(let r): return "Unavailable: \(r)"
        }
    }
}

// MARK: - Send Context

/// Everything a provider needs to handle a single message send.
struct ProviderSendContext {
    let message: String
    let sessionId: String
    let branchId: String
    let model: String?
    let workingDirectory: String?
    let project: String?

    /// Parent branch's session ID (for fork/resume inheritance)
    let parentSessionId: String?

    /// True if this is the first message in the session
    let isNewSession: Bool
}
