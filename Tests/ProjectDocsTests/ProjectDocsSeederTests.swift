import XCTest
@testable import WorldTree

final class ProjectDocsSeederTests: XCTestCase {
    func testWorldTreeSeedCapturesCuratedPlanningSignals() {
        let source = ProjectDocsSeedSource(
            projectName: "WorldTree",
            workingDirectory: "/Users/evanprimeau/Development/WorldTree",
            projectType: .swift,
            gitBranch: "main",
            isDirty: true,
            readme: "# World Tree\nA native macOS conversation workspace for orchestrating project work.",
            documentExcerpts: [
                ProjectDocExcerpt(
                    title: "Mission",
                    summary: "Transform Canvas into the only terminal and planning surface you need.",
                    headings: ["Vision", "Strategic Phases"],
                    bullets: ["Single interface for work and planning", "Keep context attached to the project"]
                )
            ],
            conversationSignals: [
                "Docs should live under each project in the project control tree, not inside a separate Cortana-only tab."
            ]
        )

        let document = ProjectDocsSeeder.seededDocument(from: source, now: .distantPast)

        XCTAssertTrue(document.overview.contains("Current branch: main with uncommitted changes."))
        XCTAssertTrue(document.desiredOutcome.contains("Retire the dedicated Cortana planning tab"))
        XCTAssertTrue(document.planOutline.contains("Claude"))
        XCTAssertTrue(document.decisionLog.contains("Obsidian clone"))
        XCTAssertTrue(document.promptNotes.contains("Ask Codex for direct repo inspection"))
        XCTAssertTrue(document.cortanaNotes.contains("Docs should live under each project"))
    }

    func testGenericSeedFallsBackToDocsAndReadme() {
        let source = ProjectDocsSeedSource(
            projectName: "BookBuddy",
            workingDirectory: "/Users/evanprimeau/Development/BookBuddy",
            projectType: .swift,
            gitBranch: nil,
            isDirty: false,
            readme: """
            # BookBuddy

            BookBuddy is a reading app for managing a library, tracking progress, and staying focused on the next book.
            """,
            documentExcerpts: [
                ProjectDocExcerpt(
                    title: "Roadmap",
                    summary: "Capture the reading experience and simplify planning.",
                    headings: ["Phase 1", "Phase 2"],
                    bullets: ["Track reading progress", "Preserve buy-once product constraints"]
                )
            ],
            conversationSignals: []
        )

        let document = ProjectDocsSeeder.seededDocument(from: source, now: .distantPast)

        XCTAssertTrue(document.overview.contains("BookBuddy is a reading app"))
        XCTAssertTrue(document.desiredOutcome.contains("Track reading progress"))
        XCTAssertTrue(document.planOutline.contains("Phase 1."))
        XCTAssertTrue(document.decisionLog.contains("Preserve buy-once product constraints"))
        XCTAssertTrue(document.cortanaNotes.contains("durable project notebook"))
    }
}
