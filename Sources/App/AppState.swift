import Foundation

/// Which top-level view shows in the detail pane when no tree is selected.
enum SidebarDestination: String, Hashable {
    case commandCenter
    case projectDocs
    case tickets
    case timeline
    case graph
    case mcpTools
}

/// Global app state — selected tree, selected branch, daemon connection status.
///
/// Uses @Observable for per-property tracking — views only re-render when
/// the specific properties they read change, not on ANY property change.
/// This eliminates cascade re-renders across the entire view hierarchy.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var selectedTreeId: String? {
        didSet { UserDefaults.standard.set(selectedTreeId, forKey: AppConstants.lastSelectedTreeIdKey) }
    }
    var selectedBranchId: String? {
        didSet { UserDefaults.standard.set(selectedBranchId, forKey: AppConstants.lastSelectedBranchIdKey) }
    }
    var selectedProjectName: String?
    var selectedProjectPath: String?
    var sidebarDestination: SidebarDestination = .commandCenter
    var showGlobalSearch: Bool = false
    var daemonConnected: Bool = false
    var simpleMode: Bool = false {
        didSet { UserDefaults.standard.set(simpleMode, forKey: AppConstants.simpleModeKey) }
    }
    /// Non-nil if the database failed to initialize — surfaced as an alert in WorldTreeApp.
    var dbSetupError: Error? = nil
    /// Number of active tasks across all projects (dispatches + jobs)
    var activeTaskCount: Int = 0
    /// Whether the terminal panel is visible — persisted so branch switches don't hide it.
    var terminalVisible: Bool = false {
        didSet { UserDefaults.standard.set(terminalVisible, forKey: "terminalVisible") }
    }

    /// Navigation history for branch back/forward.
    /// Each entry stores both treeId and branchId so both are restored on navigate.
    var branchHistory: [(treeId: String, branchId: String)] = []
    var branchHistoryIndex: Int = -1

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

        simpleMode = UserDefaults.standard.bool(forKey: AppConstants.simpleModeKey)
        terminalVisible = UserDefaults.standard.bool(forKey: "terminalVisible")

        // Restore last selected conversation from previous session
        selectedTreeId = UserDefaults.standard.string(forKey: AppConstants.lastSelectedTreeIdKey)
        selectedBranchId = UserDefaults.standard.string(forKey: AppConstants.lastSelectedBranchIdKey)
    }

    func selectBranch(_ branchId: String, in treeId: String) {
        // Notify the old branch's ViewModel it's being replaced — allows clean detach
        // before SwiftUI destroys the view. The stream keeps running; only the subscriber is removed.
        if let oldBranch = selectedBranchId, oldBranch != branchId {
            NotificationCenter.default.post(
                name: .branchWillSwitch,
                object: nil,
                userInfo: ["oldBranchId": oldBranch, "newBranchId": branchId]
            )
        }
        clearProjectSelection()
        selectedTreeId = treeId
        selectedBranchId = branchId

        // Trim forward history and push
        if branchHistoryIndex < branchHistory.count - 1 {
            branchHistory = Array(branchHistory.prefix(branchHistoryIndex + 1))
        }
        branchHistory.append((treeId: treeId, branchId: branchId))

        // Cap history at 100 entries — drop oldest when exceeded
        if branchHistory.count > 100 {
            let overflow = branchHistory.count - 100
            branchHistory.removeFirst(overflow)
            branchHistoryIndex = max(branchHistoryIndex - overflow, 0)
        }

        branchHistoryIndex = branchHistory.count - 1
    }

    func navigateBack() {
        guard branchHistoryIndex > 0 else { return }
        branchHistoryIndex -= 1
        let entry = branchHistory[branchHistoryIndex]
        clearProjectSelection()
        selectedTreeId = entry.treeId
        selectedBranchId = entry.branchId
    }

    func navigateForward() {
        guard branchHistoryIndex < branchHistory.count - 1 else { return }
        branchHistoryIndex += 1
        let entry = branchHistory[branchHistoryIndex]
        clearProjectSelection()
        selectedTreeId = entry.treeId
        selectedBranchId = entry.branchId
    }

    var canGoBack: Bool { branchHistoryIndex > 0 }
    var canGoForward: Bool { branchHistoryIndex < branchHistory.count - 1 }
    
    func selectProject(_ path: String) {
        selectedProjectPath = path
    }

    func selectProjectDocs(name: String, path: String?) {
        selectedTreeId = nil
        selectedBranchId = nil
        selectedProjectName = name
        selectedProjectPath = path
        sidebarDestination = .projectDocs
    }

    func clearProjectSelection() {
        selectedProjectName = nil
        selectedProjectPath = nil
    }
}
