import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
final class WorldTreeStore {
    var trees: [TreeSummary] = []
    var currentTree: TreeSummary?
    var branches: [BranchSummary] = []
    var currentBranch: BranchSummary?
    var messages: [Message] = []
    var streamingText: String = ""
    var isStreaming: Bool = false
    /// When true, the next branches_list response will auto-select the best branch
    /// instead of restoring the last-viewed one. Set when the user taps a project row.
    var pendingAutoSelectBranch = false
    /// Active and recently-completed tool chips shown inline during streaming.
    var activeToolChips: [ToolChip] = []
    /// Per-branch draft text. Key = branchId. Binding-compatible via draftText(for:).
    private var drafts: [String: String] = [:]

    init() {
        loadDrafts()
        NotificationCenter.default.addObserver(
            forName: .webSocketMessageReceived,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let text = notification.object as? String else { return }
            MainActor.assumeIsolated { self?.processIncoming(text) }
        }
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistDrafts() }
        }
        #endif
    }

    private func processIncoming(_ text: String) {
        guard let event = MessageParser.parse(text) else { return }

        switch event.type {
        case "trees_list":
            if let payload = event.trees {
                trees = payload
                // TASK-028: auto-navigate to last-viewed tree on first load.
                restoreLastTree()
            }
        case "branches_list":
            if let payload = event.branches {
                branches = payload
                if pendingAutoSelectBranch {
                    pendingAutoSelectBranch = false
                    // Prefer the main branch; fall back to the first available.
                    let best = payload.first(where: { $0.branchType == "main" }) ?? payload.first
                    if let best { selectBranch(best) }
                } else {
                    // TASK-028: auto-navigate to last-viewed branch after branches load.
                    restoreLastBranch()
                }
            }
        case "messages_list":
            if let payload = event.messages {
                messages = payload
                streamingText = ""
                isStreaming = false
                activeToolChips = []
            }
        case "token":
            if let token = event.token {
                isStreaming = true
                streamingText += token
            }
        case "tool_status":
            if let name = event.toolName, let status = event.toolStatus {
                switch status {
                case "started":
                    activeToolChips.append(.running(name))
                case "completed":
                    if let idx = activeToolChips.lastIndex(where: { $0.toolName == name && $0.state == .running }) {
                        activeToolChips[idx].state = .done
                    }
                case "error":
                    if let idx = activeToolChips.lastIndex(where: { $0.toolName == name && $0.state == .running }) {
                        activeToolChips[idx].state = .failed
                    }
                default:
                    break
                }
            }
        case "message_complete":
            if !streamingText.isEmpty {
                let role = event.messageRole ?? "assistant"
                let msg = Message(
                    id: event.messageId ?? UUID().uuidString,
                    role: role,
                    content: streamingText,
                    createdAt: ISO8601DateFormatter().string(from: Date())
                )
                messages.append(msg)
                if role == "assistant" {
                    NotificationManager.shared.notifyAssistantMessage(
                        treeName: currentTree?.name ?? "World Tree",
                        branchName: currentBranch?.title,
                        text: streamingText
                    )
                }
                streamingText = ""
            }
            isStreaming = false
            activeToolChips = []
        default:
            break
        }
    }
}

// MARK: - Persistence (TASK-028: session restore)

extension WorldTreeStore {
    private enum Keys {
        static let lastTreeId   = "lastTreeId"
        static let lastBranchId = "lastBranchId"
    }

    var persistedTreeId: String? {
        get { UserDefaults.standard.string(forKey: Keys.lastTreeId) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastTreeId) }
    }

    var persistedBranchId: String? {
        get { UserDefaults.standard.string(forKey: Keys.lastBranchId) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastBranchId) }
    }

    func selectTree(_ tree: TreeSummary) {
        currentTree = tree
        persistedTreeId = tree.id
    }

    func selectBranch(_ branch: BranchSummary) {
        currentBranch = branch
        persistedBranchId = branch.id
        // Clear stale messages so BranchView shows a clean state while new ones load.
        messages = []
        streamingText = ""
        isStreaming = false
        activeToolChips = []
    }

    /// Navigate back from BranchView to BranchesListView.
    func clearBranch() {
        currentBranch = nil
        persistedBranchId = nil
        messages = []
        streamingText = ""
        isStreaming = false
        activeToolChips = []
    }

    /// Navigate back from BranchesListView to TreeListView.
    func clearTree() {
        currentTree = nil
        persistedTreeId = nil
        currentBranch = nil
        persistedBranchId = nil
        branches = []
        messages = []
        streamingText = ""
        isStreaming = false
        activeToolChips = []
    }

    /// Called once after the tree list arrives. Navigates to the last-viewed tree if it still exists.
    /// Falls back silently (shows tree list) when the tree no longer exists on the server.
    func restoreLastTree() {
        // Only restore when no tree is already selected (i.e. fresh connection).
        guard currentTree == nil, let id = persistedTreeId else { return }
        if let match = trees.first(where: { $0.id == id }) {
            currentTree = match
            // Branch restore happens in restoreLastBranch() after branches load.
        } else {
            // Tree gone — clear persisted IDs so we don't retry every connection.
            persistedTreeId = nil
            persistedBranchId = nil
        }
    }

    /// Called once after the branch list arrives. Navigates to the last-viewed branch if it exists.
    /// Falls back to the branch list view when the branch no longer exists.
    func restoreLastBranch() {
        guard currentBranch == nil,
              currentTree != nil,
              let id = persistedBranchId else { return }
        if let match = branches.first(where: { $0.id == id }) {
            currentBranch = match
        } else {
            // Branch gone — clear only the branch ID; keep the tree selection.
            persistedBranchId = nil
        }
    }
}

// MARK: - Draft Persistence (TASK-023)

extension WorldTreeStore {
    private static let draftsKey = "branchDrafts"

    /// Get the current draft for a branch.
    func draft(for branchId: String) -> String {
        drafts[branchId] ?? ""
    }

    /// Save a draft for a branch. Pass an empty string to clear.
    func saveDraft(_ text: String, for branchId: String) {
        if text.isEmpty {
            drafts.removeValue(forKey: branchId)
        } else {
            drafts[branchId] = text
        }
    }

    /// Persist all drafts to UserDefaults (called on app background).
    func persistDrafts() {
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        UserDefaults.standard.set(data, forKey: Self.draftsKey)
    }

    /// Load drafts from UserDefaults (called on init).
    fileprivate func loadDrafts() {
        guard let data = UserDefaults.standard.data(forKey: Self.draftsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        drafts = decoded
    }
}
