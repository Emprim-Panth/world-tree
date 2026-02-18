import Foundation
import Combine

/// Global app state — selected tree, selected branch, daemon connection status.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selectedTreeId: String?
    @Published var selectedBranchId: String?
    @Published var selectedProjectPath: String?
    @Published var daemonConnected: Bool = false

    /// Navigation history for branch back/forward.
    /// Each entry stores both treeId and branchId so both are restored on navigate.
    @Published var branchHistory: [(treeId: String, branchId: String)] = []
    @Published var branchHistoryIndex: Int = -1

    private init() {}

    func selectBranch(_ branchId: String, in treeId: String) {
        selectedTreeId = treeId
        selectedBranchId = branchId

        // Trim forward history and push
        if branchHistoryIndex < branchHistory.count - 1 {
            branchHistory = Array(branchHistory.prefix(branchHistoryIndex + 1))
        }
        branchHistory.append((treeId: treeId, branchId: branchId))
        branchHistoryIndex = branchHistory.count - 1
    }

    func navigateBack() {
        guard branchHistoryIndex > 0 else { return }
        branchHistoryIndex -= 1
        let entry = branchHistory[branchHistoryIndex]
        selectedTreeId = entry.treeId
        selectedBranchId = entry.branchId
    }

    func navigateForward() {
        guard branchHistoryIndex < branchHistory.count - 1 else { return }
        branchHistoryIndex += 1
        let entry = branchHistory[branchHistoryIndex]
        selectedTreeId = entry.treeId
        selectedBranchId = entry.branchId
    }

    var canGoBack: Bool { branchHistoryIndex > 0 }
    var canGoForward: Bool { branchHistoryIndex < branchHistory.count - 1 }
    
    func selectProject(_ path: String) {
        selectedProjectPath = path
    }
}
