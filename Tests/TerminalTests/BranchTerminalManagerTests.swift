import XCTest
@testable import WorldTree

@MainActor
final class BranchTerminalManagerTests: XCTestCase {
    func testBestProjectSessionMatchPrefersProjectNamedActiveSession() {
        let candidates = [
            BranchTerminalManager.ProjectSessionCandidate(
                sessionName: "side-shell",
                currentPath: "/Users/evanprimeau/Development/WorldTree/Sources",
                activity: 6,
                currentCommand: "zsh",
                windowCount: 1
            ),
            BranchTerminalManager.ProjectSessionCandidate(
                sessionName: "WorldTree",
                currentPath: "/Users/evanprimeau/Development/WorldTree",
                activity: 42,
                currentCommand: "swift",
                windowCount: 3
            )
        ]

        let winner = BranchTerminalManager.bestProjectSessionMatch(
            project: "WorldTree",
            for: "/Users/evanprimeau/Development/WorldTree",
            candidates: candidates
        )

        XCTAssertEqual(winner?.sessionName, "WorldTree")
    }

    func testBestProjectSessionMatchRejectsCanvasSessionsWhenRealProjectSessionExists() {
        let candidates = [
            BranchTerminalManager.ProjectSessionCandidate(
                sessionName: "canvas-deadbeef",
                currentPath: "/Users/evanprimeau/Development/WorldTree",
                activity: 1,
                currentCommand: "zsh",
                windowCount: 1
            ),
            BranchTerminalManager.ProjectSessionCandidate(
                sessionName: "wt-worldtree",
                currentPath: "/Users/evanprimeau/Development/WorldTree",
                activity: 20,
                currentCommand: "tmux",
                windowCount: 2
            )
        ]

        let winner = BranchTerminalManager.bestProjectSessionMatch(
            project: "WorldTree",
            for: "/Users/evanprimeau/Development/WorldTree",
            candidates: candidates
        )

        XCTAssertEqual(winner?.sessionName, "wt-worldtree")
    }

    func testBestProjectSessionMatchCanReuseProjectNamedSessionWithoutPathMatch() {
        let candidates = [
            BranchTerminalManager.ProjectSessionCandidate(
                sessionName: "WorldTree",
                currentPath: "/Users/evanprimeau",
                activity: 15,
                currentCommand: "swift",
                windowCount: 4
            ),
            BranchTerminalManager.ProjectSessionCandidate(
                sessionName: "scratch",
                currentPath: "/tmp",
                activity: 2,
                currentCommand: "zsh",
                windowCount: 1
            )
        ]

        let winner = BranchTerminalManager.bestProjectSessionMatch(
            project: "WorldTree",
            for: "/Users/evanprimeau/Development/WorldTree",
            candidates: candidates
        )

        XCTAssertEqual(winner?.sessionName, "WorldTree")
    }

    func testPreferredProjectSessionNameReplacesSyntheticFallbackWithRealSession() {
        let candidates = [
            BranchTerminalManager.ProjectSessionCandidate(
                sessionName: "main",
                currentPath: "/Users/evanprimeau/Development/WorldTree",
                activity: 7,
                currentCommand: "swift",
                windowCount: 4
            )
        ]

        let winner = BranchTerminalManager.preferredProjectSessionName(
            project: "WorldTree",
            for: "/Users/evanprimeau/Development/WorldTree",
            storedSession: "wt-worldtree",
            storedSessionIsAlive: true,
            candidates: candidates
        )

        XCTAssertEqual(winner, "main")
    }

    func testPreferredProjectSessionNameKeepsNamedSessionWhenItIsAlreadyReal() {
        let winner = BranchTerminalManager.preferredProjectSessionName(
            project: "WorldTree",
            for: "/Users/evanprimeau/Development/WorldTree",
            storedSession: "main",
            storedSessionIsAlive: true,
            candidates: []
        )

        XCTAssertEqual(winner, "main")
    }

    func testWorkspacePathsMatchTreatsProjectRootAndSubdirectoryAsSameWorkspace() {
        XCTAssertTrue(
            BranchTerminalManager.workspacePathsMatch(
                "/Users/evanprimeau/Development/WorldTree",
                "/Users/evanprimeau/Development/WorldTree/Sources/App"
            )
        )
    }

    func testWorkspacePathsMatchRejectsSiblingProjects() {
        XCTAssertFalse(
            BranchTerminalManager.workspacePathsMatch(
                "/Users/evanprimeau/Development/WorldTree",
                "/Users/evanprimeau/Development/BookBuddy"
            )
        )
    }
}
