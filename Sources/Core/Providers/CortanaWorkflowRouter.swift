import Foundation

enum CortanaWorkflowClass: String, Equatable, Sendable {
    case quick
    case coding
    case deepReview
    case balanced
}

struct CortanaWorkflowRoute: Equatable, Sendable {
    let taskClass: CortanaWorkflowClass
    let primaryModelId: String
    let reviewerModelId: String?
    let reason: String
}

enum CortanaWorkflowRouter {
    private static let quickKeywords = [
        "quick", "brief", "summary", "summarize", "rewrite", "reword",
        "rename", "title", "status", "small", "simple", "list"
    ]

    private static let codingKeywords = [
        "implement", "fix", "debug", "refactor", "build", "test", "compile",
        "repo", "project", "terminal", "shell", "command", "file", "files",
        "swift", "rust", "typescript", "python", "xcode", "git", "mcp",
        "stack trace", "failing", "bug", "error"
    ]

    private static let deepReviewKeywords = [
        "architecture", "design", "tradeoff", "trade-off", "strategy", "review",
        "audit", "security", "migration", "workflow", "plan", "root cause",
        "investigate", "analyze", "analysis", "compare"
    ]

    static func plan(
        message: String,
        preferredModelId: String,
        autoRoutingEnabled: Bool,
        crossCheckEnabled: Bool,
        hasClaudeFamily: Bool,
        hasCodex: Bool
    ) -> CortanaWorkflowRoute {
        guard autoRoutingEnabled else {
            return CortanaWorkflowRoute(
                taskClass: .balanced,
                primaryModelId: preferredModelId,
                reviewerModelId: nil,
                reason: "Manual routing is active, so Cortana keeps the selected default model."
            )
        }

        let messageLower = message.lowercased()
        let quickScore = score(messageLower, keywords: quickKeywords)
        let codingScore = score(messageLower, keywords: codingKeywords)
        let deepScore = score(messageLower, keywords: deepReviewKeywords)

        if quickScore > 0, quickScore >= codingScore, quickScore >= deepScore, hasClaudeFamily {
            return CortanaWorkflowRoute(
                taskClass: .quick,
                primaryModelId: "claude-haiku-4-5-20251001",
                reviewerModelId: nil,
                reason: "Fast summarization and low-risk edits are best handled by Haiku."
            )
        }

        if deepScore > codingScore, hasClaudeFamily {
            return CortanaWorkflowRoute(
                taskClass: .deepReview,
                primaryModelId: "claude-opus-4-6",
                reviewerModelId: crossCheckEnabled && hasCodex ? "codex" : nil,
                reason: "Architecture, review, and tradeoff work route to Opus for deeper reasoning."
            )
        }

        if codingScore > 0, hasCodex {
            let reviewer: String?
            if crossCheckEnabled, hasClaudeFamily {
                reviewer = deepScore > 0 ? "claude-opus-4-6" : "claude-sonnet-4-6"
            } else {
                reviewer = nil
            }

            return CortanaWorkflowRoute(
                taskClass: .coding,
                primaryModelId: "codex",
                reviewerModelId: reviewer,
                reason: "Implementation, debugging, and repo-driving work route to Codex first."
            )
        }

        if hasClaudeFamily {
            let reviewer = crossCheckEnabled && hasCodex ? "codex" : nil
            return CortanaWorkflowRoute(
                taskClass: .balanced,
                primaryModelId: "claude-sonnet-4-6",
                reviewerModelId: reviewer,
                reason: "General work defaults to Sonnet as the balanced Claude lane."
            )
        }

        if hasCodex {
            return CortanaWorkflowRoute(
                taskClass: codingScore > 0 ? .coding : .balanced,
                primaryModelId: "codex",
                reviewerModelId: nil,
                reason: "Claude is unavailable, so Codex becomes the general-purpose fallback."
            )
        }

        return CortanaWorkflowRoute(
            taskClass: .balanced,
            primaryModelId: preferredModelId,
            reviewerModelId: nil,
            reason: "No alternate providers are available, so Cortana keeps the requested model."
        )
    }

    private static func score(_ message: String, keywords: [String]) -> Int {
        keywords.reduce(into: 0) { total, keyword in
            if message.contains(keyword) {
                total += 1
            }
        }
    }
}
