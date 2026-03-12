import Foundation

// MARK: - Token Dashboard Aggregate Models

struct SessionBurnRate: Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let project: String?
    let tokensPerMinute: Double
    let totalTokens: Int
    let windowStart: Date
}

struct DailyTokenTotal: Identifiable {
    var id: String { "\(date.timeIntervalSinceReferenceDate)" }
    let date: Date              // day boundary (UTC midnight)
    let inputTokens: Int
    let outputTokens: Int
    let model: String?

    var total: Int { inputTokens + outputTokens }
}

struct ProjectTokenSummary: Identifiable {
    var id: String { project }
    let project: String
    let totalIn: Int
    let totalOut: Int
    let activeSessions: Int
    let lastActivityAt: Date?

    var total: Int { totalIn + totalOut }
}

struct SessionContextUsage: Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let project: String?
    let estimatedUsed: Int
    let maxContext: Int
    let percentUsed: Double     // 0.0–1.0
}
