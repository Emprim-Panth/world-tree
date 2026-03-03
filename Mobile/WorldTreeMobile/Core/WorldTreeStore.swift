import Foundation
import Observation
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Handoff

struct HandoffRequest {
    let treeId: String
    let branchId: String
}

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
    /// Branches that are currently streaming (used for typing indicators in list views).
    var streamingBranchIds: Set<String> = []
    /// Per-branch streaming text — persists across branch switches so the indicator
    /// and partial response are visible when the user navigates away and returns.
    private(set) var branchStreamingText: [String: String] = [:]
    /// Branch → tree mapping, populated when branches load, used to show
    /// streaming/unread indicators on tree rows in TreeListView.
    private(set) var branchToTree: [String: String] = [:]
    /// When each tree was last opened by the user (used to compute unread badge state).
    private(set) var treeLastViewedAt: [String: Date] = [:]
    /// When true, the next branches_list response will auto-select the best branch
    /// instead of restoring the last-viewed one. Set when the user taps a project row.
    var pendingAutoSelectBranch = false
    /// When true, the next branches_list response will navigate to the newest branch.
    /// Set immediately before sending create_branch.
    var pendingNavigateToNewBranch = false
    /// Active and recently-completed tool chips shown inline during streaming.
    var activeToolChips: [ToolChip] = []
    /// True while a get_messages request is in-flight (no messages arrived yet).
    var isLoadingHistory: Bool = false
    /// True while a list_branches request is in-flight (set when a tree is selected).
    var isLoadingBranches: Bool = false
    /// True after the server acknowledges our message but before the first response token arrives.
    /// Drives the "Seen ✓✓" + thinking indicator in the mobile UI.
    var serverSeen: Bool = false
    /// True when the currently displayed messages were loaded from the local cache
    /// (either because we are offline or while waiting for the server to respond).
    /// Drives the "Offline — showing cached messages" banner in BranchView.
    var showingCachedMessages: Bool = false
    /// Per-branch draft text. Key = branchId. Binding-compatible via draftText(for:).
    private var drafts: [String: String] = [:]
    /// Pending Handoff navigation — set by onContinueUserActivity, consumed once trees/branches load.
    var pendingHandoff: HandoffRequest?
    /// Pending Share Extension payload — set by the worldtree:// URL handler,
    /// consumed by BranchView.onAppear to pre-fill the message input.
    var pendingShare: PendingShare?
    /// Pending lock-screen reply (TASK-062). Set by NotificationManager.onLockScreenReply,
    /// observed by BranchView which sends it via ConnectionManager.
    var pendingReply: String?

    init() {
        loadDrafts()
        loadLastViewedDates()
        // TASK-062: route lock-screen replies back to the active branch.
        NotificationManager.shared.onLockScreenReply = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.pendingReply = text
            }
        }
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
                LocalDatabase.shared.replaceTrees(payload)
                // TASK-028: auto-navigate to last-viewed tree on first load.
                restoreLastTree()
            }
        case "branches_list":
            if let payload = event.branches {
                isLoadingBranches = false
                branches = payload
                if let treeId = currentTree?.id {
                    LocalDatabase.shared.replaceBranches(payload, treeId: treeId)
                    // Build branch→tree mapping for typing/unread indicators
                    for branch in payload {
                        branchToTree[branch.id] = treeId
                    }
                }
                if pendingNavigateToNewBranch {
                    pendingNavigateToNewBranch = false
                    // Navigate to the newest branch that isn't the current one.
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let newest = payload
                        .filter { $0.id != currentBranch?.id }
                        .max { (iso.date(from: $0.createdAt) ?? .distantPast) < (iso.date(from: $1.createdAt) ?? .distantPast) }
                    if let newest { selectBranch(newest) }
                } else if pendingAutoSelectBranch {
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
                isLoadingHistory = false
                serverSeen = false
                showingCachedMessages = false
                if let branchId = currentBranch?.id {
                    LocalDatabase.shared.replaceMessages(payload, branchId: branchId)
                }
            }
        case "message_received":
            serverSeen = true

        case "token":
            if let token = event.token {
                serverSeen = false  // server is actively responding — hide the seen indicator
                isStreaming = true
                streamingText += token
                // Track per-branch streaming state for indicators + persistence
                let bid = event.branchId ?? currentBranch?.id
                if let bid {
                    streamingBranchIds.insert(bid)
                    branchStreamingText[bid, default: ""] += token
                }
                // TASK-058: feed token batches to Live Activity (coalesced internally)
                LiveActivityManager.shared.appendToken(token)
                // TASK-065: buffer token for Watch (coalesced to 1/sec internally)
                PhoneSessionManager.shared.bufferToken(token)
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
            let bid = event.branchId ?? currentBranch?.id
            // Prefer per-branch buffer (covers case where user switched away mid-stream)
            let finalContent = bid.flatMap { branchStreamingText[$0] } ?? streamingText
            if !finalContent.isEmpty {
                let role = event.messageRole ?? "assistant"
                let msg = Message(
                    id: event.messageId ?? UUID().uuidString,
                    role: role,
                    content: finalContent,
                    createdAt: ISO8601DateFormatter().string(from: Date())
                )
                // Only append to visible messages if we're still on this branch
                if bid == nil || bid == currentBranch?.id {
                    messages.append(msg)
                }
                if let bid {
                    LocalDatabase.shared.upsertMessage(msg, branchId: bid)
                } else if let branchId = currentBranch?.id {
                    LocalDatabase.shared.upsertMessage(msg, branchId: branchId)
                }
                if role == "assistant" {
                    NotificationManager.shared.notifyAssistantMessage(
                        treeName: currentTree?.name ?? "World Tree",
                        branchName: currentBranch?.title,
                        text: finalContent
                    )
                    // TASK-063: update widget data so the home screen widget stays current
                    updateWidgetData(snippet: finalContent)
                }
                // TASK-058: end Live Activity now that the response is complete
                LiveActivityManager.shared.endActivity()
                // TASK-065: notify Watch streaming is done
                PhoneSessionManager.shared.sendStreamingEnd(finalText: finalContent)
            }
            // Clear per-branch streaming state
            if let bid {
                streamingBranchIds.remove(bid)
                branchStreamingText.removeValue(forKey: bid)
            }
            // Clear global state (only if this was the current branch's stream)
            if bid == nil || bid == currentBranch?.id {
                streamingText = ""
            }
            isStreaming = false
            activeToolChips = []
        case "error":
            // Surface daemon/pipeline errors as an assistant message instead of silently dropping.
            let errText = event.errorMessage ?? "An error occurred."
            let msg = Message(
                id: "error-\(UUID().uuidString)",
                role: "assistant",
                content: "⚠️ \(errText)",
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            messages.append(msg)
            isStreaming = false
            activeToolChips = []
            isLoadingHistory = false
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
        isLoadingBranches = true
        branches = []
        // Mark tree as viewed now so the unread badge clears immediately on tap
        treeLastViewedAt[tree.id] = Date()
        persistLastViewedDates()
    }

    /// True when the tree has new content since the user last opened it.
    func hasUnread(_ tree: TreeSummary) -> Bool {
        guard let lastViewed = treeLastViewedAt[tree.id] else { return false }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fmt.date(from: tree.updatedAt) { return date > lastViewed }
        fmt.formatOptions = [.withInternetDateTime]
        if let date = fmt.date(from: tree.updatedAt) { return date > lastViewed }
        return false
    }

    /// True when any branch of the given tree is currently streaming a response.
    func isTreeStreaming(_ tree: TreeSummary) -> Bool {
        streamingBranchIds.contains { branchToTree[$0] == tree.id }
    }

    /// Immediately append a user message so the UI shows it before the server echoes it back.
    /// Also starts a Live Activity so the response is visible on the lock screen (TASK-058).
    func addOptimisticMessage(content: String) {
        let msg = Message(
            id: "optimistic-\(UUID().uuidString)",
            role: "user",
            content: content,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        messages.append(msg)

        // TASK-058: start Live Activity when user sends a message
        let treeName = currentTree?.name ?? "World Tree"
        let branchName = currentBranch?.title
        LiveActivityManager.shared.startActivity(treeName: treeName, branchName: branchName)
        // TASK-065: notify Watch companion
        PhoneSessionManager.shared.sendStreamingStart(treeName: treeName, branchName: branchName)
    }

    func selectBranch(_ branch: BranchSummary) {
        // Save current streaming text before switching so it can be restored on return
        if isStreaming, let currentId = currentBranch?.id {
            branchStreamingText[currentId] = streamingText
        }
        // Keep branch→tree mapping up-to-date
        if let treeId = currentTree?.id {
            branchToTree[branch.id] = treeId
        }
        currentBranch = branch
        persistedBranchId = branch.id
        // Clear stale messages so BranchView shows a clean state while new ones load.
        messages = []
        activeToolChips = []
        serverSeen = false
        showingCachedMessages = false
        // Restore streaming state if this branch was already streaming
        if streamingBranchIds.contains(branch.id) {
            streamingText = branchStreamingText[branch.id] ?? ""
            isStreaming = true
        } else {
            streamingText = ""
            isStreaming = false
        }
    }

    /// Navigate back from BranchView to BranchesListView.
    func clearBranch() {
        // Preserve streaming text in the per-branch buffer so the list indicator stays visible
        if isStreaming, let currentId = currentBranch?.id {
            branchStreamingText[currentId] = streamingText
        }
        currentBranch = nil
        persistedBranchId = nil
        messages = []
        streamingText = ""
        isStreaming = false
        activeToolChips = []
        isLoadingHistory = false
        showingCachedMessages = false
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
        isLoadingHistory = false
        isLoadingBranches = false
        showingCachedMessages = false
    }

    /// Called once after the tree list arrives. Navigates to the last-viewed tree if it still exists.
    /// Handoff takes priority over persisted session restore.
    /// Falls back silently (shows tree list) when the tree no longer exists on the server.
    func restoreLastTree() {
        guard currentTree == nil else { return }

        // Handoff navigation takes priority
        let targetId = pendingHandoff?.treeId ?? persistedTreeId
        guard let id = targetId else { return }

        if let match = trees.first(where: { $0.id == id }) {
            currentTree = match
            // Branch restore happens in restoreLastBranch() after branches load.
        } else {
            // Tree gone — clear persisted IDs so we don't retry every connection.
            if pendingHandoff == nil {
                persistedTreeId = nil
                persistedBranchId = nil
            }
        }
    }

    // MARK: - Offline cache loading (TASK-057)

    /// Load cached trees when offline. Shows whatever was last synced from the server.
    func loadCachedTrees() {
        let cached = LocalDatabase.shared.loadTrees()
        guard !cached.isEmpty else { return }
        trees = cached
        restoreLastTree()
    }

    /// Load cached branches for the current tree when offline.
    func loadCachedBranches(treeId: String) {
        let cached = LocalDatabase.shared.loadBranches(treeId: treeId)
        guard !cached.isEmpty else {
            isLoadingBranches = false
            return
        }
        branches = cached
        isLoadingBranches = false
        restoreLastBranch()
    }

    /// Load cached messages for a branch when offline (or while waiting for the server).
    /// Sets showingCachedMessages = true so BranchView can display an offline banner.
    func loadCachedMessages(branchId: String) {
        let cached = LocalDatabase.shared.loadMessages(branchId: branchId)
        guard !cached.isEmpty else {
            // Nothing cached — leave the spinner up until the server responds (or forever if offline).
            return
        }
        messages = cached
        isLoadingHistory = false
        showingCachedMessages = true
    }

    /// Called once after the branch list arrives. Navigates to the last-viewed branch if it exists.
    /// Falls back to the branch list view when the branch no longer exists.
    func restoreLastBranch() {
        guard currentBranch == nil, currentTree != nil else { return }

        // Handoff navigation takes priority
        let targetId = pendingHandoff?.branchId ?? persistedBranchId
        guard let id = targetId else { return }

        if let match = branches.first(where: { $0.id == id }) {
            currentBranch = match
        } else {
            if pendingHandoff == nil {
                persistedBranchId = nil
            }
        }
        // Consume the handoff request regardless of whether we found the branch
        pendingHandoff = nil
    }
}

// MARK: - Widget + Notification Reply Integration

extension WorldTreeStore {
    private enum WidgetKeys {
        static let suiteName = "group.com.evanprimeau.worldtree"
        static let lastMessage = "widget_lastMessage"
        static let lastTreeName = "widget_lastTreeName"
        static let lastBranchName = "widget_lastBranchName"
        static let lastUpdated = "widget_lastUpdated"
    }

    /// Write the latest assistant message to the shared App Group so the Widget can display it.
    /// Reload the widget timeline so the home screen snippet is fresh within ~30 seconds.
    func updateWidgetData(snippet: String) {
        guard let suite = UserDefaults(suiteName: WidgetKeys.suiteName) else { return }
        suite.set(String(snippet.prefix(200)), forKey: WidgetKeys.lastMessage)
        suite.set(currentTree?.name ?? "World Tree", forKey: WidgetKeys.lastTreeName)
        suite.set(currentBranch?.title, forKey: WidgetKeys.lastBranchName)
        suite.set(Date(), forKey: WidgetKeys.lastUpdated)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Register the lock-screen reply callback so NotificationManager can route replies
    /// back to the active branch. Call once, early in the app lifecycle.
    func registerLockScreenReplyHandler() {
        NotificationManager.shared.onLockScreenReply = { [weak self] replyText in
            guard let self else { return }
            // Set pendingReply — observed by BranchView which sends it via ConnectionManager.
            self.pendingReply = replyText
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

// MARK: - Last-Viewed Date Persistence (unread badge tracking)

extension WorldTreeStore {
    private static let lastViewedKey = "treeLastViewedAt"

    /// Load last-viewed timestamps from UserDefaults (called on init).
    func loadLastViewedDates() {
        guard let data = UserDefaults.standard.data(forKey: Self.lastViewedKey),
              let dict = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return }
        treeLastViewedAt = dict.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Persist last-viewed timestamps to UserDefaults.
    func persistLastViewedDates() {
        let dict = treeLastViewedAt.mapValues { $0.timeIntervalSince1970 }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: Self.lastViewedKey)
        }
    }
}
