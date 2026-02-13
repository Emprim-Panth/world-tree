import Foundation

// MARK: - Context Pressure Levels

/// How full the CLI's context window is (estimated heuristically).
enum PressureLevel: String, Codable {
    case low       // <50% — green, all good
    case moderate  // 50-75% — yellow, getting warm
    case high      // >75% — orange, rotation recommended
    case critical  // >90% — red, rotation required

    var color: String {
        switch self {
        case .low: return "green"
        case .moderate: return "yellow"
        case .high: return "orange"
        case .critical: return "red"
        }
    }

    var shouldRotate: Bool {
        self == .high || self == .critical
    }
}

// MARK: - Context Pressure Estimator

/// Heuristic token estimation for CLI sessions.
///
/// The CLI manages its own context internally and doesn't expose token counts.
/// We estimate from Canvas-side data:
/// - Message content character counts → token estimate via `chars / 3.5 * 1.15`
/// - Tool event overhead (each tool call ≈ 500 tokens for start+end+framing)
/// - Turn overhead (system prompt re-injection, ~2000 tokens per turn)
///
/// This matches the formula in `ConversationStateManager`.
enum ContextPressureEstimator {

    /// Claude's maximum context window size.
    static let maxContextTokens = 200_000

    /// Overhead per tool call (start + end + framing).
    static let toolOverheadTokens = 500

    /// Overhead per conversation turn (system prompt fragments, role markers).
    static let turnOverheadTokens = 2_000

    /// Base system prompt size (Cortana identity + CLAUDE.md + tools).
    static let systemPromptTokens = 8_000

    // MARK: - Full Estimate

    /// Estimate token count from Canvas-side message data and tool events.
    ///
    /// - Parameters:
    ///   - messages: All messages in the session
    ///   - toolEventCount: Number of tool events (toolStart + toolEnd pairs)
    /// - Returns: Estimated token count and pressure level
    static func estimate(
        messages: [Message],
        toolEventCount: Int = 0
    ) -> (tokens: Int, level: PressureLevel) {
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        let turnCount = messages.filter { $0.role == .user }.count

        let messageTokens = Int(Double(totalChars) / 3.5 * 1.15)
        let toolTokens = toolEventCount * toolOverheadTokens
        let turnTokens = turnCount * turnOverheadTokens
        let totalTokens = systemPromptTokens + messageTokens + toolTokens + turnTokens

        let level = pressureLevel(for: totalTokens)
        return (tokens: totalTokens, level: level)
    }

    // MARK: - Quick Estimate

    /// Quick pressure check from summary stats (no message array needed).
    /// Useful for refreshObservability() where we already have counts.
    static func quickEstimate(
        messageCount: Int,
        totalChars: Int,
        toolEventCount: Int
    ) -> (tokens: Int, level: PressureLevel) {
        let turnCount = messageCount / 2 // Approximate: half are user messages
        let messageTokens = Int(Double(totalChars) / 3.5 * 1.15)
        let toolTokens = toolEventCount * toolOverheadTokens
        let turnTokens = turnCount * turnOverheadTokens
        let totalTokens = systemPromptTokens + messageTokens + toolTokens + turnTokens

        let level = pressureLevel(for: totalTokens)
        return (tokens: totalTokens, level: level)
    }

    // MARK: - Usage Ratio

    /// Returns 0.0 to 1.0+ representing how full the context is.
    static func usageRatio(tokens: Int) -> Double {
        Double(tokens) / Double(maxContextTokens)
    }

    // MARK: - Private

    private static func pressureLevel(for tokens: Int) -> PressureLevel {
        let ratio = Double(tokens) / Double(maxContextTokens)
        switch ratio {
        case ..<0.5:
            return .low
        case 0.5..<0.75:
            return .moderate
        case 0.75..<0.9:
            return .high
        default:
            return .critical
        }
    }
}
