import XCTest
@testable import WorldTree

final class CortanaWorkflowRouterTests: XCTestCase {
    func testManualModeKeepsPreferredModel() {
        let route = CortanaWorkflowRouter.plan(
            message: "Implement a fix",
            preferredModelId: "claude-sonnet-4-6",
            autoRoutingEnabled: false,
            crossCheckEnabled: true,
            hasClaudeFamily: true,
            hasCodex: true
        )

        XCTAssertEqual(route.primaryModelId, "claude-sonnet-4-6")
        XCTAssertNil(route.reviewerModelId)
    }

    func testCodingWorkRoutesToCodexWithClaudeReviewer() {
        let route = CortanaWorkflowRouter.plan(
            message: "Implement the failing test fix, patch the repo, and run build commands",
            preferredModelId: "claude-sonnet-4-6",
            autoRoutingEnabled: true,
            crossCheckEnabled: true,
            hasClaudeFamily: true,
            hasCodex: true
        )

        XCTAssertEqual(route.taskClass, .coding)
        XCTAssertEqual(route.primaryModelId, "codex")
        XCTAssertEqual(route.reviewerModelId, "claude-sonnet-4-6")
    }

    func testArchitectureReviewRoutesToOpus() {
        let route = CortanaWorkflowRouter.plan(
            message: "Review the workflow architecture, tradeoffs, and migration strategy",
            preferredModelId: "claude-sonnet-4-6",
            autoRoutingEnabled: true,
            crossCheckEnabled: true,
            hasClaudeFamily: true,
            hasCodex: true
        )

        XCTAssertEqual(route.taskClass, .deepReview)
        XCTAssertEqual(route.primaryModelId, "claude-opus-4-6")
        XCTAssertEqual(route.reviewerModelId, "codex")
    }

    func testQuickWorkRoutesToHaiku() {
        let route = CortanaWorkflowRouter.plan(
            message: "Quick summary and rename this branch title",
            preferredModelId: "claude-sonnet-4-6",
            autoRoutingEnabled: true,
            crossCheckEnabled: true,
            hasClaudeFamily: true,
            hasCodex: true
        )

        XCTAssertEqual(route.taskClass, .quick)
        XCTAssertEqual(route.primaryModelId, "claude-haiku-4-5-20251001")
        XCTAssertNil(route.reviewerModelId)
    }
}
