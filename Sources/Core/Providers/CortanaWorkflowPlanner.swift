import Foundation

struct CortanaWorkflowReviewPlan: Equatable, Sendable {
    let mode: WorkflowReviewMode
    let modelId: String
    let runsAutomatically: Bool
}

struct CortanaWorkflowExecutionPlan: Equatable, Sendable {
    let templateId: String?
    let primaryModelId: String
    let primaryReason: String
    let reviewer: CortanaWorkflowReviewPlan?
    let usesAutomaticRouting: Bool

    var autoReviewEnabled: Bool {
        reviewer?.runsAutomatically == true
    }
}

@MainActor
enum CortanaWorkflowPlanner {
    static func plan(
        message: String,
        preferredModelId: String? = nil,
        template: WorkflowTemplate? = nil
    ) -> CortanaWorkflowExecutionPlan {
        let effectiveMessage = composePrimaryPrompt(message: message, template: template)
        let manualModel = ModelCatalog.canonicalModelId(for: preferredModelId)

        let primaryModelId: String
        let primaryReason: String
        let usesAutomaticRouting: Bool
        let routedReviewerModelId: String?

        if let manualModel {
            primaryModelId = manualModel
            primaryReason = "Manual model selection is locked for this workflow."
            usesAutomaticRouting = false
            routedReviewerModelId = nil
        } else {
            let route = ProviderManager.shared.routePreview(
                message: effectiveMessage,
                preferredModelId: ModelCatalog.canonicalModelId(for: template?.suggestedModel)
            )
            primaryModelId = route.primaryModelId
            primaryReason = route.reason
            usesAutomaticRouting = true
            routedReviewerModelId = route.reviewerModelId
        }

        let reviewMode = template?.reviewMode ?? .none
        let reviewerModelId = resolveReviewerModel(
            for: reviewMode,
            primaryModelId: primaryModelId,
            routedReviewerModelId: routedReviewerModelId
        )

        let reviewer = reviewerModelId.map {
            CortanaWorkflowReviewPlan(
                mode: reviewMode,
                modelId: $0,
                runsAutomatically: reviewMode.runsAutomatically
            )
        }

        return CortanaWorkflowExecutionPlan(
            templateId: template?.id,
            primaryModelId: primaryModelId,
            primaryReason: primaryReason,
            reviewer: reviewer,
            usesAutomaticRouting: usesAutomaticRouting
        )
    }

    static func composePrimaryPrompt(message: String, template: WorkflowTemplate?) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return template?.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func composeSystemPrompt(
        template: WorkflowTemplate?,
        extraSystemPrompt: String? = nil
    ) -> String? {
        let segments = [extraSystemPrompt, template?.systemContext]
            .compactMap { text -> String? in
                guard let text else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

        guard !segments.isEmpty else { return nil }
        return segments.joined(separator: "\n\n")
    }

    static func composeReviewerPrompt(
        review: CortanaWorkflowReviewPlan,
        originalTask: String,
        primaryModelId: String,
        primaryResult: String
    ) -> String {
        let clippedResult: String
        if primaryResult.count > 20_000 {
            clippedResult = String(primaryResult.prefix(20_000)) + "\n\n[Primary output truncated for review.]"
        } else {
            clippedResult = primaryResult
        }

        switch review.mode {
        case .qaChain:
            return """
                Review the completed implementation below as the QA stage before shipping.

                Original task:
                \(originalTask)

                Primary model:
                \(ModelCatalog.label(for: primaryModelId))

                Focus on:
                - correctness and regressions
                - missed edge cases
                - missing or weak tests
                - risky file changes or commands

                Put findings first. If the implementation looks clean, say so explicitly and call out any remaining risks.

                Primary output:
                \(clippedResult)
                """

        case .challenge:
            return """
                Challenge the design or solution below.

                Original task:
                \(originalTask)

                Primary model:
                \(ModelCatalog.label(for: primaryModelId))

                Attack assumptions, weak tradeoffs, hidden complexity, and safer alternatives. Findings first.

                Primary output:
                \(clippedResult)
                """

        case .none:
            return clippedResult
        }
    }

    static func composeReviewerSystemPrompt(
        review: CortanaWorkflowReviewPlan,
        template: WorkflowTemplate?,
        extraSystemPrompt: String? = nil
    ) -> String? {
        let stageDirective: String
        switch review.mode {
        case .qaChain:
            stageDirective = """
                You are the QA stage of Cortana's workflow chain. Review the prior result, verify what you can, and do not silently assume correctness.
                """
        case .challenge:
            stageDirective = """
                You are the challenge stage of Cortana's workflow chain. Push against assumptions, expose weak tradeoffs, and surface what the first pass missed.
                """
        case .none:
            stageDirective = ""
        }

        return composeSystemPrompt(
            template: template,
            extraSystemPrompt: [extraSystemPrompt, stageDirective]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        )
    }

    private static func resolveReviewerModel(
        for reviewMode: WorkflowReviewMode,
        primaryModelId: String,
        routedReviewerModelId: String?
    ) -> String? {
        guard reviewMode != .none else {
            return nil
        }

        let availableProviderIds = Set(ProviderManager.shared.modelSelectableProviderIds)
        let hasCodex = availableProviderIds.contains("codex-cli")
        let hasClaude = availableProviderIds.contains("claude-code") || availableProviderIds.contains("anthropic-api")

        if let routedReviewerModelId = ModelCatalog.canonicalModelId(for: routedReviewerModelId),
           ProviderManager.shared.preferredProviderId(forModelId: routedReviewerModelId) != nil {
            return routedReviewerModelId
        }

        switch reviewMode {
        case .qaChain:
            if ModelCatalog.family(for: primaryModelId) == .codex, hasClaude {
                return "claude-sonnet-4-6"
            }
            if hasCodex {
                return "codex"
            }
            if hasClaude {
                return "claude-sonnet-4-6"
            }
            return nil

        case .challenge:
            if ModelCatalog.family(for: primaryModelId) == .codex, hasClaude {
                return "claude-opus-4-6"
            }
            if hasCodex {
                return "codex"
            }
            if hasClaude {
                return "claude-opus-4-6"
            }
            return nil

        case .none:
            return nil
        }
    }
}
