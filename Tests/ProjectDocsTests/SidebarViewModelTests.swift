import XCTest
@testable import WorldTree

@MainActor
final class SidebarViewModelTests: XCTestCase {
    func testVisibleSidebarTreesHidesTelegramBridgeTrees() {
        let visible = ConversationTree(
            id: "tree-visible",
            name: "WorldTree",
            project: "WorldTree",
            workingDirectory: "/tmp/WorldTree",
            createdAt: Date(),
            updatedAt: Date(),
            archived: false
        )
        let telegram = ConversationTree(
            id: "tree-telegram",
            name: "Telegram • WorldTree",
            project: "WorldTree",
            workingDirectory: "/tmp/WorldTree",
            createdAt: Date(),
            updatedAt: Date(),
            archived: false
        )

        let result = SidebarViewModel.visibleSidebarTrees(from: [visible, telegram])

        XCTAssertEqual(result.map(\.id), ["tree-visible"])
    }

    func testProjectActivityPrefersCachedProjectModificationDate() {
        let tree = ConversationTree(
            id: "tree-worldtree",
            name: "WorldTree",
            project: "WorldTree",
            workingDirectory: "/tmp/WorldTree",
            createdAt: .distantPast,
            updatedAt: Date(timeIntervalSince1970: 100),
            archived: false
        )
        let cachedProject = CachedProject(
            path: "/tmp/WorldTree",
            name: "WorldTree",
            type: .swift,
            gitBranch: "main",
            gitDirty: true,
            lastModified: Date(timeIntervalSince1970: 200),
            lastScanned: .distantPast
        )

        let activity = SidebarViewModel.projectActivity(
            for: "WorldTree",
            trees: [tree],
            cachedProject: cachedProject
        )

        XCTAssertEqual(activity, Date(timeIntervalSince1970: 200))
    }

    func testRecentSortDoesNotLetManualOrderHideNewerProjects() {
        let sorted = SidebarViewModel.sortProjectNames(
            ["Older", "Newer"],
            sortOrder: .recentDesc,
            manualOrder: ["Older", "Newer"]
        ) { name in
            name == "Newer"
                ? Date(timeIntervalSince1970: 200)
                : Date(timeIntervalSince1970: 100)
        }

        XCTAssertEqual(sorted, ["Newer", "Older"])
    }
}
