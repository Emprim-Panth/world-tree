import Foundation
import Combine

/// Global app state — selected tree, selected branch, daemon connection status.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selectedTreeId: String? {
        didSet { UserDefaults.standard.set(selectedTreeId, forKey: "lastSelectedTreeId") }
    }
    @Published var selectedBranchId: String? {
        didSet { UserDefaults.standard.set(selectedBranchId, forKey: "lastSelectedBranchId") }
    }
    @Published var selectedProjectPath: String?
    @Published var daemonConnected: Bool = false
    @Published var simpleMode: Bool {
        didSet { UserDefaults.standard.set(simpleMode, forKey: "worldtree.simpleMode") }
    }
    /// Mermaid source code currently shown in the diagram side panel. nil = panel hidden.
    @Published var activeMermaidCode: String? = nil
    /// Non-nil if the database failed to initialize — surfaced as an alert in WorldTreeApp.
    @Published var dbSetupError: Error? = nil

    /// Navigation history for branch back/forward.
    /// Each entry stores both treeId and branchId so both are restored on navigate.
    @Published var branchHistory: [(treeId: String, branchId: String)] = []
    @Published var branchHistoryIndex: Int = -1

    private init() {
        // Setup DB here — before any view renders — so SingleDocumentViewModel.init()
        // always reads from a ready database. Previously setupDatabase() was called in
        // WorldTreeApp.onAppear, which fires AFTER child .onAppear calls, causing a race
        // where SingleDocumentViewModel got a nil dbPool and fell back to a fake session UUID.
        do {
            try DatabaseManager.shared.setup()
            JobQueue.configure()
        } catch {
            dbSetupError = error
        }

        simpleMode = UserDefaults.standard.bool(forKey: "worldtree.simpleMode")

        // Restore last selected conversation from previous session
        selectedTreeId = UserDefaults.standard.string(forKey: "lastSelectedTreeId")
        selectedBranchId = UserDefaults.standard.string(forKey: "lastSelectedBranchId")
    }

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
