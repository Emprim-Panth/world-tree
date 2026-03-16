import XCTest
@testable import WorldTree

@MainActor
final class CortanaWorkflowPlannerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: AppConstants.cortanaAutoRoutingEnabledKey)
        UserDefaults.standard.set(true, forKey: AppConstants.cortanaCrossCheckEnabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppConstants.cortanaAutoRoutingEnabledKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.cortanaCrossCheckEnabledKey)
        super.tearDown()
    }

    func testManualModelSelectionStaysLocked() {
        let plan = CortanaWorkflowPlanner.plan(
            message: "Implement the authentication service and run the repo tests",
            preferredModelId: "claude-opus-4-6",
            template: nil
        )

        XCTAssertEqual(plan.primaryModelId, "claude-opus-4-6")
        XCTAssertFalse(plan.usesAutomaticRouting)
        XCTAssertNil(plan.reviewer)
    }

    func testImplementReviewTemplateArmsQAChain() {
        let plan = CortanaWorkflowPlanner.plan(
            message: "Build the full macOS app shell, wire the settings flow, and verify the project builds cleanly",
            preferredModelId: nil,
            template: .implementReview
        )

        XCTAssertEqual(plan.primaryModelId, "codex")
        XCTAssertEqual(plan.reviewer?.mode, .qaChain)
        XCTAssertTrue(plan.autoReviewEnabled)
    }

    func testFastTriageStaysSinglePass() {
        let plan = CortanaWorkflowPlanner.plan(
            message: "Quick triage this warning and tell me the next step",
            preferredModelId: nil,
            template: .fastTriage
        )

        XCTAssertEqual(plan.primaryModelId, "claude-haiku-4-5-20251001")
        XCTAssertNil(plan.reviewer)
        XCTAssertTrue(plan.usesAutomaticRouting)
    }

    func testExecutionBriefsSplitCodexAndClaudeLanes() {
        let brief = CortanaBrief(
            title: "Harden project docs flow",
            summary: "Tighten the docs-driven planning surface and verify provider-specific handoff prompts.",
            projectName: "WorldTree",
            workingDirectory: "/Users/evanprimeau/Development/WorldTree",
            recommendedModelId: "codex",
            routeReason: "Implementation-heavy repo work with verification.",
            goals: [
                "Make the docs panel the planning source of truth",
                "Generate materially different execution briefs per model"
            ],
            constraints: [
                "Preserve project-native UX patterns",
                "Run targeted verification after changes"
            ],
            sourceMessageId: UUID()
        )

        let codexPrompt = brief.executionPrompt(for: .codex)
        let claudePrompt = brief.executionPrompt(for: .claude)

        XCTAssertNotEqual(codexPrompt, claudePrompt)
        XCTAssertTrue(codexPrompt.contains("Drive the next implementation slice directly in the repo."))
        XCTAssertTrue(codexPrompt.contains("Implement the requested slice end to end instead of stopping at analysis."))
        XCTAssertTrue(claudePrompt.contains("Sharpen the approach where strategy, architecture, or prompt design matters before execution moves forward."))
        XCTAssertTrue(claudePrompt.contains("Call out where Codex would be the better follow-on lane for direct repo execution."))
    }
}
