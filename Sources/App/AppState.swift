import Foundation

/// Which top-level view shows in the detail pane when no tree is selected.
enum SidebarDestination: String, Hashable {
    case commandCenter
    case projectDocs
    case tickets
    case timeline
    case mcpTools
    case brain
    case factory
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
    /// Per-tree last-viewed branch — restored when opening a tree so the user
    /// returns to where they left off rather than always opening the root branch.
    private(set) var lastBranchPerTree: [String: String] = {
        UserDefaults.standard.dictionary(forKey: AppConstants.lastBranchPerTreeKey) as? [String: String] ?? [:]
    }()

    /// Display name of the currently selected tree — shown in toolbar title.
    /// Set alongside selectedTreeId so views can show the name without a DB lookup.
    var selectedTreeName: String?
    /// Bumped on every selection change. SplitContainer keys DetailRouter on this
    /// to force recreation without relying on @Observable propagation through
    /// NavigationSplitView's detail closure (which is unreliable on macOS).
    var detailRefreshKey: String = UUID().uuidString

    var selectedProjectName: String?
    var selectedProjectPath: String?
    var sidebarDestination: SidebarDestination = .commandCenter
    var showGlobalSearch: Bool = false
    var daemonConnected: Bool = false
    /// Non-nil if the database failed to initialize — surfaced as an alert in WorldTreeApp.
    var dbSetupError: Error? = nil
    /// Number of active tasks across all projects (dispatches + jobs)
    var activeTaskCount: Int = 0
    /// Whether the terminal panel is visible — persisted so branch switches don't hide it.
    /// Key bumped to v2 so existing users (who had false saved) get the new default of true.
    var terminalVisible: Bool = false {
        didSet { UserDefaults.standard.set(terminalVisible, forKey: "terminalVisible_v2") }
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

        // Default to visible — terminal-on is the baseline experience.
        // v2 key: existing machines never set this, so they get true on first launch.
        let hasSetTerminalVisible = UserDefaults.standard.object(forKey: "terminalVisible_v2") != nil
        terminalVisible = hasSetTerminalVisible ? UserDefaults.standard.bool(forKey: "terminalVisible_v2") : true

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
        if selectedTreeId != treeId {
            selectedTreeName = (try? TreeStore.shared.getTree(treeId))?.name
        }
        detailRefreshKey = UUID().uuidString
        selectedTreeId = treeId
        selectedBranchId = branchId

        // Remember the last-viewed branch for this tree so navigating back to it
        // restores the user's position instead of always opening the root branch.
        lastBranchPerTree[treeId] = branchId
        UserDefaults.standard.set(lastBranchPerTree, forKey: AppConstants.lastBranchPerTreeKey)

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
        let oldBranchId = selectedBranchId
        branchHistoryIndex -= 1
        let entry = branchHistory[branchHistoryIndex]
        if let old = oldBranchId, old != entry.branchId {
            NotificationCenter.default.post(
                name: .branchWillSwitch,
                object: nil,
                userInfo: ["oldBranchId": old, "newBranchId": entry.branchId]
            )
        }
        clearProjectSelection()
        selectedTreeName = (try? TreeStore.shared.getTree(entry.treeId))?.name
        detailRefreshKey = UUID().uuidString
        selectedTreeId = entry.treeId
        selectedBranchId = entry.branchId
    }

    func navigateForward() {
        guard branchHistoryIndex < branchHistory.count - 1 else { return }
        let oldBranchId = selectedBranchId
        branchHistoryIndex += 1
        let entry = branchHistory[branchHistoryIndex]
        if let old = oldBranchId, old != entry.branchId {
            NotificationCenter.default.post(
                name: .branchWillSwitch,
                object: nil,
                userInfo: ["oldBranchId": old, "newBranchId": entry.branchId]
            )
        }
        clearProjectSelection()
        selectedTreeName = (try? TreeStore.shared.getTree(entry.treeId))?.name
        detailRefreshKey = UUID().uuidString
        selectedTreeId = entry.treeId
        selectedBranchId = entry.branchId
    }

    var canGoBack: Bool { branchHistoryIndex > 0 }
    var canGoForward: Bool { branchHistoryIndex < branchHistory.count - 1 }

    /// Returns the last-viewed branch for a given tree, or nil if not recorded.
    func lastBranch(for treeId: String) -> String? {
        lastBranchPerTree[treeId]
    }
    
    /// Select a tree from the sidebar. Fires branchWillSwitch for the old branch so
    /// its ViewModel can detach from the stream and write a snapshot before teardown.
    func selectTree(_ treeId: String) {
        if let oldBranch = selectedBranchId {
            NotificationCenter.default.post(
                name: .branchWillSwitch,
                object: nil,
                userInfo: ["oldBranchId": oldBranch, "newBranchId": ""]
            )
        }
        clearProjectSelection()
        selectedTreeName = (try? TreeStore.shared.getTree(treeId))?.name
        detailRefreshKey = UUID().uuidString
        selectedBranchId = nil
        selectedTreeId = treeId
    }

    func selectProject(_ path: String) {
        selectedProjectPath = path
    }

    func selectProjectDocs(name: String, path: String?) {
        if let old = selectedBranchId {
            NotificationCenter.default.post(
                name: .branchWillSwitch,
                object: nil,
                userInfo: ["oldBranchId": old, "newBranchId": ""]
            )
        }
        selectedTreeId = nil
        selectedBranchId = nil
        selectedTreeName = nil
        selectedProjectName = name
        selectedProjectPath = path
        sidebarDestination = .projectDocs
    }

    func clearProjectSelection() {
        selectedProjectName = nil
        selectedProjectPath = nil
    }
}
