import XCTest
@testable import WorldTree

final class CortanaPlannerBriefTests: XCTestCase {
    func testCodexExecutionPromptEmphasizesDirectRepoWork() {
        let brief = makeBrief()

        let prompt = brief.executionPrompt(for: .codex)

        XCTAssertTrue(prompt.contains("Cortana execution brief for Codex"))
        XCTAssertTrue(prompt.contains("Inspect the existing code before changing it."))
        XCTAssertTrue(prompt.contains("Run the narrowest meaningful verification for touched areas."))
        XCTAssertFalse(prompt.contains("Start by clarifying the problem shape, risks, and tradeoffs."))
    }

    func testClaudeExecutionPromptEmphasizesReasoningAndTradeoffs() {
        let brief = makeBrief()

        let prompt = brief.executionPrompt(for: .claude)

        XCTAssertTrue(prompt.contains("Cortana execution brief for Claude"))
        XCTAssertTrue(prompt.contains("Start by clarifying the problem shape, risks, and tradeoffs."))
        XCTAssertTrue(prompt.contains("Call out where Codex would be the better follow-on lane for direct repo execution."))
        XCTAssertFalse(prompt.contains("Inspect the existing code before changing it."))
    }

    func testPromotionTargetMetadataMatchesLaneIntent() {
        XCTAssertEqual(CortanaPromotionTarget.codex.promptHeadline, "Built for direct repo work")
        XCTAssertEqual(CortanaPromotionTarget.claude.promptHeadline, "Built for strategy and hard reasoning")
        XCTAssertTrue(CortanaPromotionTarget.codex.promptGuidance.contains("inspect the codebase"))
        XCTAssertTrue(CortanaPromotionTarget.claude.promptGuidance.contains("architectural judgment"))
    }

    private func makeBrief() -> CortanaBrief {
        CortanaBrief(
            title: "Project docs execution",
            summary: "Add a docs lane and shape prompts for each model.",
            projectName: "WorldTree",
            workingDirectory: "/Users/evanprimeau/Development/WorldTree",
            recommendedModelId: "codex",
            routeReason: "Implementation-heavy UI work with local verification.",
            goals: [
                "Add a docs surface to the project tree",
                "Generate prompt variants for Codex and Claude"
            ],
            constraints: [
                "Preserve existing project navigation patterns."
            ],
            sourceMessageId: UUID()
        )
    }
}
