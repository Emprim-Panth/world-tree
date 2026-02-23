import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

@Observable
final class WorldTreeStore {
    var trees: [TreeSummary] = []
    var currentTree: TreeSummary?
    var branches: [BranchSummary] = []
    var currentBranch: BranchSummary?
    var messages: [Message] = []
    var streamingText: String = ""
    var isStreaming: Bool = false
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
            self?.processIncoming(text)
        }
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.persistDrafts()
        }
        #endif
    }

    private func processIncoming(_ text: String) {
        guard let event = MessageParser.parse(text) else { return }

        switch event.type {
        case "trees":
            if let payload = event.trees {
                trees = payload
                // TASK-028: auto-navigate to last-viewed tree on first load.
                restoreLastTree()
            }
        case "branches":
            if let payload = event.branches {
                branches = payload
                // TASK-028: auto-navigate to last-viewed branch after branches load.
                restoreLastBranch()
            }
        case "history":
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
        case "tool_start":
            if let name = event.toolName {
                activeToolChips.append(.running(name))
            }
        case "tool_end":
            if let name = event.toolName,
               let idx = activeToolChips.lastIndex(where: { $0.toolName == name && $0.state == .running }) {
                activeToolChips[idx].state = (event.toolError == true) ? .failed : .done
            }
        case "done":
            if !streamingText.isEmpty {
                let msg = Message(
                    id: UUID().uuidString,
                    role: "assistant",
                    content: streamingText,
                    index: messages.count
                )
                messages.append(msg)
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
