import SwiftUI
import Foundation
import GRDB

// Environment key so child views (e.g. Mermaid blocks) can cancel the
// conversation's horizontal padding and span the full detail pane width.
private struct ConversationHPadKey: EnvironmentKey {
    static let defaultValue: CGFloat = 24
}
extension EnvironmentValues {
    var conversationHPad: CGFloat {
        get { self[ConversationHPadKey.self] }
        set { self[ConversationHPadKey.self] = newValue }
    }
}

/// Google Docs-style collaborative document editor for conversations
struct DocumentEditorView: View {
    @StateObject private var viewModel: DocumentEditorViewModel
    @FocusState private var isFocused: Bool
    @State private var hoveredSectionId: UUID?
    @State private var selectedSuggestionIndex = 0
    @State private var forkBranchType: BranchType = .conversation
    @State private var showSearch = false
    @State private var searchQuery = ""
    @Environment(\.scenePhase) private var scenePhase

    // Error alert
    @State private var showErrorAlert = false
    @State private var errorAlertMessage = ""

    let branchId: String
    let sessionId: String
    var parentBranchLayout: BranchLayoutViewModel?

    init(sessionId: String,
         branchId: String,
         workingDirectory: String,
         parentBranchLayout: BranchLayoutViewModel? = nil) {
        self.sessionId = sessionId
        self.branchId = branchId
        self.parentBranchLayout = parentBranchLayout
        _viewModel = StateObject(wrappedValue: DocumentEditorViewModel(
            sessionId: sessionId,
            branchId: branchId,
            workingDirectory: workingDirectory
        ))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // --- Scrollable message area ---
                // The ScrollView is only mounted once messages have loaded (initialLoadDone).
                // This ensures .defaultScrollAnchor(.bottom) fires on the FIRST layout pass
                // with actual content present — not on an empty container that wastes the anchor.
                ScrollViewReader { proxy in
                    if !viewModel.initialLoadDone && viewModel.document.sections.isEmpty {
                        // Loading state — brief, before GRDB delivers messages
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.regular)
                            Text("Loading conversation…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                    } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // Pagination trigger — loads older messages when visible
                            if viewModel.hasMoreMessages {
                                Button {
                                    let firstId = viewModel.document.sections.first?.id
                                    Task {
                                        await viewModel.loadOlderMessages()
                                        if let id = firstId {
                                            proxy.scrollTo(id, anchor: .top)
                                        }
                                    }
                                } label: {
                                    Text("Load earlier messages")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 12)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.plain)
                            }

                            // Empty state — shown before the first message
                            if viewModel.document.sections.isEmpty && !viewModel.isProcessing {
                                EmptyConversationView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 60)
                            }

                            // Persisted messages — rendered in order of arrival
                            ForEach(viewModel.document.sections) { section in
                                DocumentSectionView(
                                    section: section,
                                    isHovered: hoveredSectionId == section.id,
                                    showInferButton: !viewModel.isRootBranch,
                                    onEdit: { newContent in viewModel.updateSection(section.id, content: newContent) },
                                    onBranch: { viewModel.requestFork(from: section.id) },
                                    onInfer: { viewModel.inferFinding(from: section.id) },
                                    onNavigateToBranch: { branchId in
                                        if let treeId = viewModel.treeId {
                                            AppState.shared.selectBranch(branchId, in: treeId)
                                        }
                                    }
                                )
                                .onHover { hovered in hoveredSectionId = hovered ? section.id : nil }
                                .id(section.id)
                                .opacity(searchMatchOpacity(for: section))
                                .animation(.easeInOut(duration: 0.15), value: searchQuery)
                            }

                        // Streaming + thinking indicator — isolated to StreamingLayerView
                        // so 10fps token updates don't re-render the document section list.
                        StreamingLayerView(streaming: viewModel.streaming)

                        // Scroll anchor — used by proxy.scrollTo("scroll-bottom", anchor: .bottom) throughout
                        Color.clear.frame(height: 1).id("scroll-bottom")
                    }
                    .padding(.horizontal, max(24, (geometry.size.width - 800) / 2))
                    .padding(.vertical, 24)
                    .environment(\.conversationHPad, max(24, (geometry.size.width - 800) / 2))
                }
                .defaultScrollAnchor(.bottom)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if showSearch {
                        ConversationSearchBar(query: $searchQuery, matchCount: searchMatchCount, onDismiss: {
                            showSearch = false
                            searchQuery = ""
                            isFocused = true
                        })
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: showSearch)
                .background(Color(nsColor: .textBackgroundColor))
                .onDisappear {
                    // Do NOT cancel in-flight streams on disappear — the user may have just
                    // switched to another window or branch. Cancelling here cuts off responses
                    // mid-generation. The stream keeps running in the background; the user gets
                    // a notification when done. Only deinit (true deallocation) performs cleanup.
                    viewModel.writeSnapshotCheckpoint()
                }
                .sheet(item: $viewModel.pendingForkMessage) { message in
                    ForkMenu(
                        sourceMessage: message,
                        branchType: $forkBranchType,
                        branch: viewModel.currentBranch,
                        onCreated: { newBranchId in
                            viewModel.pendingForkMessage = nil
                            guard !newBranchId.isEmpty,
                                  let treeId = viewModel.treeId else { return }
                            AppState.shared.selectBranch(newBranchId, in: treeId)
                            if let branch = try? TreeStore.shared.getBranch(newBranchId) {
                                viewModel.parentBranchLayout?.visibleBranches.append(branch)
                            }
                        }
                    )
                }
                // Mark initial scroll complete after ScrollView's first layout pass.
                // Because we gate ScrollView creation on initialLoadDone, the content
                // is present on the very first render — .defaultScrollAnchor(.bottom) works.
                .onAppear {
                    viewModel.initialScrollComplete = true
                }
                // Auto-scroll for subsequent new messages — only if user is at the bottom.
                .onChange(of: viewModel.document.sections.count) { _, _ in
                    guard viewModel.initialScrollComplete else { return }
                    guard viewModel.streaming.content == nil, !viewModel.isProcessing else { return }
                    if viewModel.isScrolledToBottom {
                        proxy.scrollTo("scroll-bottom", anchor: .bottom)
                    }
                }
                .onReceive(viewModel.streaming.$content) { content in
                    guard viewModel.initialLoadDone else { return }
                    if content != nil {
                        if viewModel.isScrolledToBottom {
                            proxy.scrollTo("scroll-bottom", anchor: .bottom)
                        }
                    } else {
                        proxy.scrollTo("scroll-bottom", anchor: .bottom)
                        if viewModel.hasNewStreamContent { viewModel.hasNewStreamContent = false }
                    }
                }
                .modifier(ScrollBottomTracker(isScrolledToBottom: $viewModel.isScrolledToBottom,
                                             hasNewStreamContent: $viewModel.hasNewStreamContent))
                .overlay(alignment: .bottomTrailing) {
                    if viewModel.hasNewStreamContent && !viewModel.isScrolledToBottom {
                        ScrollToBottomFAB {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                proxy.scrollTo("scroll-bottom", anchor: .bottom)
                            }
                            viewModel.hasNewStreamContent = false
                        }
                        .padding(20)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2),
                           value: viewModel.hasNewStreamContent && !viewModel.isScrolledToBottom)
                .onChange(of: viewModel.isProcessing) { _, processing in
                    guard viewModel.initialLoadDone else { return }
                    if processing && viewModel.streaming.content == nil {
                        proxy.scrollTo("scroll-bottom", anchor: .bottom)
                    }
                    if !processing && viewModel.isScrolledToBottom {
                        proxy.scrollTo("scroll-bottom", anchor: .bottom)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .showConversationSearch)) { _ in
                    withAnimation { showSearch = true }
                    isFocused = false
                }
                .onReceive(NotificationCenter.default.publisher(for: .choiceSelected)) { notification in
                    guard let choice = notification.userInfo?["choice"] as? String else { return }
                    viewModel.currentInput = choice
                    viewModel.submitInput()
                }
                .onReceive(NotificationCenter.default.publisher(for: .forkLastMessage)) { note in
                    guard let targetBranchId = note.object as? String,
                          targetBranchId == branchId else { return }
                    viewModel.forkFromLastMessage()
                }
                }  // closes else (ScrollView branch)
            }  // closes ScrollViewReader
            .onAppear {
                viewModel.claimWindowOwnership()
                viewModel.loadDocument()
                viewModel.parentBranchLayout = parentBranchLayout
                // Delay focus so the view is fully in the responder chain before we request it.
                // Without this, the focus request races with SwiftUI's layout pass and gets dropped.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    isFocused = true
                }
                let synthKey = "pending_synthesis_\(sessionId)"
                if let prompt = UserDefaults.standard.string(forKey: synthKey) {
                    UserDefaults.standard.removeObject(forKey: synthKey)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        viewModel.currentInput = prompt
                        viewModel.submitInput()
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    viewModel.claimWindowOwnership()
                } else {
                    viewModel.releaseWindowOwnership()
                }
            }
            .onDisappear {
                viewModel.releaseWindowOwnership()
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))

            // Input box — direct VStack sibling so scroll view is height-constrained above it
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    UserInputArea(
                        text: $viewModel.currentInput,
                        attachments: $viewModel.pendingAttachments,
                        isProcessing: viewModel.isProcessing,
                        onSubmit: { viewModel.submitInput() },
                        onCancel: { viewModel.cancelStream() },
                        onTabKey: {
                            if viewModel.branchOpportunity != nil {
                                selectedSuggestionIndex = (selectedSuggestionIndex + 1) % (viewModel.branchOpportunity?.suggestions.count ?? 1)
                                return true
                            }
                            return false
                        },
                        onShiftTabKey: {
                            if let opportunity = viewModel.branchOpportunity {
                                viewModel.acceptSuggestion(opportunity.suggestions[selectedSuggestionIndex])
                                selectedSuggestionIndex = 0
                                return true
                            }
                            return false
                        },
                        onCmdReturnKey: {
                            if viewModel.branchOpportunity != nil {
                                viewModel.spawnParallelBranches()
                                return true
                            }
                            return false
                        }
                    )
                    .focused($isFocused)

                    if let opportunity = viewModel.branchOpportunity {
                        BranchSuggestionChips(
                            suggestions: opportunity.suggestions,
                            selectedIndex: selectedSuggestionIndex,
                            onAccept: { suggestion in viewModel.acceptSuggestion(suggestion) },
                            onAcceptAll: { viewModel.spawnParallelBranches() },
                            onDismiss: { viewModel.branchOpportunity = nil }
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .background(.bar)
            // Hidden cancel button — Cmd+. stops the active stream
            .background {
                Button("") { viewModel.cancelStream() }
                    .keyboardShortcut(".", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
            // Cmd+L focuses the input field
            .background {
                Button("") { isFocused = true }
                    .keyboardShortcut("l", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(errorAlertMessage)
        }
        .onChange(of: viewModel.errorMessage) { _, newError in
            if let msg = newError, !msg.isEmpty {
                errorAlertMessage = msg
                showErrorAlert = true
            }
        }
    }
    }
    // MARK: - Search Helpers

    /// Opacity for a section when search is active.
    /// Full opacity (1.0) for matches, dimmed (0.3) for non-matches.
    private func searchMatchOpacity(for section: DocumentSection) -> Double {
        guard showSearch, !searchQuery.isEmpty else { return 1.0 }
        let q = searchQuery.lowercased()
        // Check plain text content
        if String(section.content.characters).lowercased().contains(q) { return 1.0 }
        // Check code blocks
        if let blocks = section.metadata.codeBlocks,
           blocks.contains(where: { $0.code.lowercased().contains(q) }) { return 1.0 }
        // Check tool call names and inputs
        if let calls = section.metadata.toolCalls,
           calls.contains(where: {
               $0.name.lowercased().contains(q) || $0.input.lowercased().contains(q)
           }) { return 1.0 }
        return 0.3
    }

    /// Number of sections matching the current search query.
    private var searchMatchCount: Int {
        guard showSearch, !searchQuery.isEmpty else { return 0 }
        return viewModel.document.sections.filter { searchMatchOpacity(for: $0) == 1.0 }.count
    }

} // end struct DocumentEditorView

// MARK: - StreamingLayerView

/// Renders only the live streaming indicator and thinking spinner.
/// Observes StreamingState directly so that token delivery at 10fps only
/// re-renders this small view — not the full document section list.
private struct StreamingLayerView: View {
    @ObservedObject var streaming: StreamingState

    var body: some View {
        if let content = streaming.content, !content.isEmpty {
            StreamingSectionView(content: content)
                .id("streaming")
        }
        if streaming.isProcessing && (streaming.content == nil || streaming.content == "") {
            ThinkingIndicatorView(toolDescription: streaming.currentTool)
                .id("thinking")
                .padding(.horizontal, 0)
                .padding(.vertical, 8)
        }
    }
}

// MARK: - StreamingState

/// Ephemeral streaming state isolated into its own ObservableObject.
/// Only StreamingLayerView observes this — DocumentEditorView does not —
/// so 10fps token flushes don't trigger full document re-renders.
final class StreamingState: ObservableObject {
    @Published var content: String?
    @Published var isProcessing = false
    @Published var currentTool: String?
}

// MARK: - ViewModel

@MainActor
class DocumentEditorViewModel: ObservableObject {
    @Published var document: ConversationDocument
    private var branchAnalysisTask: Task<Void, Never>?
    @Published var currentInput = "" {
        didSet {
            branchAnalysisTask?.cancel()
            branchAnalysisTask = Task { await analyzeForBranchOpportunities() }
            // Persist draft so it survives branch switches and window changes
            UserDefaults.standard.set(currentInput, forKey: "draft.\(branchId)")
            refreshRecoveryStatus()
            if currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scheduleRecoveryCheck()
            }
        }
    }
    @Published var pendingAttachments: [Attachment] = []
    @Published var recoveryStatusMessage: String?
    /// Streaming state in its own ObservableObject so hot-path token updates
    /// don't trigger full document re-renders. Exposed for view binding.
    let streaming = StreamingState()

    /// True while Cortana is generating a response. Backed by StreamingState
    /// so the input area and empty-state check stay reactive, but direct
    /// `@Published` also keeps ProcessingRegistry side-effects intact.
    @Published var isProcessing = false {
        didSet {
            streaming.isProcessing = isProcessing
        }
    }
    /// Guard against rapid double-sends — true while processUserInput is executing.
    private var isSending = false
    @Published var branchOpportunity: BranchOpportunity?
    /// Live token stream content — backed by StreamingState so updates at 10fps
    /// don't trigger full document re-renders via viewModel.objectWillChange.
    var streamingContent: String? {
        get { streaming.content }
        set { streaming.content = newValue }
    }
    /// Currently running tool name — backed by StreamingState for same reason.
    var currentTool: String? {
        get { streaming.currentTool }
        set { streaming.currentTool = newValue }
    }

    @Published var errorMessage: String?
    @Published var pendingForkMessage: Message?

    /// Message IDs from external sources (e.g. Telegram) — shown with 📱 indicator
    private var externalSourceMessages: Set<String> = []
    private var externalSourceObserver: NSObjectProtocol?
    private var mobileStreamTokenObserver: NSObjectProtocol?
    private var mobileStreamCompleteObserver: NSObjectProtocol?
    private var streamRecoveryObserver: NSObjectProtocol?
    private var activeStreamStartObserver: NSObjectProtocol?
    private var activeStreamCompleteObserver: NSObjectProtocol?

    /// Whether the conversation scroll view is at (or near) the bottom.
    /// False when the user has manually scrolled up — suppresses auto-scroll.
    @Published var isScrolledToBottom = true

    /// True when new streaming tokens arrived while the user was scrolled up.
    /// Drives the "scroll to bottom" FAB visibility.
    @Published var hasNewStreamContent = false

    /// True when there are older messages in the DB that haven't been loaded yet.
    @Published var hasMoreMessages = false

    /// Flips to true once on the first successful applyMessages call — used to trigger
    /// the initial scroll-to-bottom after layout is complete.
    @Published var initialLoadDone = false

    /// Flips to true after the deferred initial scroll Task actually fires.
    /// Guards onChange(sections.count) so it doesn't fire in the same frame as initialLoadDone,
    /// which would cause a premature scroll before layout is measured.
    @Published var initialScrollComplete = false

    private let pageSize = 30
    private var initialLoadComplete = false

    // MARK: - Token Batching (CADisplayLink-equivalent via main-RunLoop Timer)

    /// Accumulated tokens since the last frame flush.
    /// Written per-token; flushed to streamingContent at ~10fps by streamFlushTimer.
    private var pendingTokenBuffer = ""

    /// Fires at 10fps (100ms) on the main RunLoop to flush pendingTokenBuffer → streamingContent.
    /// 10fps is perceptually smooth for text streaming while cutting SwiftUI view
    /// re-evaluation load by ~6x compared to 60fps. Critical when many WKWebView-backed
    /// code blocks are in the view tree — each evaluation walks all NSViewRepresentable wrappers.
    private var streamFlushTimer: Timer?

    private func startStreamBatching() {
        guard streamFlushTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.pendingTokenBuffer.isEmpty else { return }
                self.flushPendingTokens()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        streamFlushTimer = timer
    }

    private func stopStreamBatching() {
        streamFlushTimer?.invalidate()
        streamFlushTimer = nil
        flushPendingTokens()  // drain any remaining tokens
    }

    /// Drain accumulated tokens to streamingContent — called at 10fps.
    private func flushPendingTokens() {
        if !pendingTokenBuffer.isEmpty {
            let chunk = pendingTokenBuffer
            pendingTokenBuffer = ""
            streamingContent = (streamingContent ?? "") + chunk
            if !isScrolledToBottom { hasNewStreamContent = true }
            // Mirror to global registry so Command Center and navigate-back can see in-progress content
            GlobalStreamRegistry.shared.appendContent(branchId: branchId, content: streamingContent ?? "")
        } else if isProcessing {
            // Navigate-back case: this ViewModel was recreated while another instance is still
            // streaming. We have no local tokens, but GlobalStreamRegistry has live content
            // being updated by the original ViewModel's still-running Task.
            // Pull it here each tick so the typing indicator shows real progress.
            if let latest = GlobalStreamRegistry.shared.currentContent(for: branchId),
               !latest.isEmpty, latest != streamingContent {
                streamingContent = latest
            }
        }
    }

    private let sessionId: String
    private let branchId: String
    private let workingDirectory: String
    private let windowOwnerId = UUID()
    private var cachedProject: String?
    /// Parent branch's session ID — loaded once at document open for --fork-session support.
    private var cachedParentSessionId: String?
    private var seenMessageIds: Set<String> = []
    /// Content of the most recently persisted assistant message.
    /// Guards against double-display when the daemon (canvas-runner.py) writes the same
    /// response to the DB independently — both writes produce different row IDs, so
    /// seenMessageIds alone can't deduplicate them. We match by content instead.
    private var pendingAssistantContent: String? = nil
    private(set) var treeId: String?
    private(set) var parentBranchId: String?
    private(set) var currentBranch: Branch?
    var isRootBranch: Bool { parentBranchId == nil }

    /// Timestamp of the last successful send — used to detect stale CLI sessions.
    /// nil = no send yet this launch (treat as stale).
    private var lastSendTimestamp: Date?
    private static let sessionStaleInterval: TimeInterval = 15 * 60  // 15 min

    /// Checkpoint summary from the last SessionRotator rotation.
    /// Non-nil means the CLI session was just compacted — next processUserInput will
    /// inject this as priority context then clear it.
    private var checkpointContext: String?

    /// Mirror text to whichever terminal is actually visible — writes directly to the
    /// terminal display via feed(), bypassing the shell process. Project terminal if a
    /// project is set (the panel shows `wt-{project}`), otherwise branch terminal.
    private func mirrorToTerminal(_ text: String) {
        if let project = cachedProject {
            BranchTerminalManager.shared.mirrorToProject(project, text: text)
        } else {
            BranchTerminalManager.shared.mirror(to: branchId, text: text)
        }
    }

    /// HH:MM:SS timestamp for terminal tool headers.
    private static func terminalTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    /// Shorten an absolute path for terminal display — replaces home dir with ~.
    private static func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: home, with: "~")
    }
    /// Stable UUID per message ID — prevents random UUIDs being generated each
    /// render cycle when msg.id is an integer string (not a UUID string).
    private var stableSectionIds: [String: UUID] = [:]
    /// GRDB ValueObservation cancellable — auto-cancels when view model is deallocated.
    private var messageObservation: AnyDatabaseCancellable?
    /// Polling timer — GRDB ValueObservation only fires for writes through the same DatabasePool.
    /// The cortana daemon writes from a separate process, so we poll every 2s to catch external writes.
    private var refreshTimer: Timer?
    /// When true, the 2s polling timer actively queries the DB. Set to false when
    /// GRDB ValueObservation is healthy (onChange fires), re-enabled on observation error.
    /// This prevents redundant polling when the observation is already delivering updates.
    private var usePollingFallback = true
    /// Retry counter for loadDocument() — prevents infinite recursion when DB is slow to initialize.
    private var loadRetryCount = 0
    /// Subscription cookie for the active ActiveStreamRegistry subscription.
    /// nil when no stream is active for this branch.
    private var activeSubscriptionId: UUID?
    /// Routes messages through daemon channel when available, falls back to ProviderManager.
    private let claudeBridge = ClaudeBridge()
    weak var parentBranchLayout: BranchLayoutViewModel?

    deinit {
        // Unsubscribe from the active stream — does NOT cancel it.
        // The Task continues running in ActiveStreamRegistry and persists the response on completion.
        //
        // NOTE: deinit is nonisolated — we access @MainActor properties via
        // MainActor.assumeIsolated since deinit of a @MainActor class is guaranteed
        // to run on the main thread in practice.
        let bid = branchId
        let subId = MainActor.assumeIsolated { activeSubscriptionId }
        if let id = subId {
            MainActor.assumeIsolated {
                ActiveStreamRegistry.shared.unsubscribe(branchId: bid, id: id)
            }
        }
        MainActor.assumeIsolated {
            BranchWindowOwnershipRegistry.shared.release(branchId: bid, ownerId: windowOwnerId)
        }
        streamFlushTimer?.invalidate()
        refreshTimer?.invalidate()
        if let observer = externalSourceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let obs = mobileStreamTokenObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = mobileStreamCompleteObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = streamRecoveryObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = activeStreamStartObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = activeStreamCompleteObserver { NotificationCenter.default.removeObserver(obs) }
    }

    init(sessionId: String, branchId: String, workingDirectory: String) {
        self.sessionId = sessionId
        self.branchId = branchId
        self.workingDirectory = workingDirectory
        self.document = ConversationDocument(
            sections: [],
            cursors: [],
            metadata: DocumentMetadata(
                totalTokens: 0,
                createdAt: Date(),
                updatedAt: Date()
            )
        )
    }

    func claimWindowOwnership() {
        BranchWindowOwnershipRegistry.shared.claim(branchId: branchId, ownerId: windowOwnerId)
    }

    func releaseWindowOwnership() {
        BranchWindowOwnershipRegistry.shared.release(branchId: branchId, ownerId: windowOwnerId)
    }

    private func isOwningWindow() -> Bool {
        BranchWindowOwnershipRegistry.shared.isOwner(branchId: branchId, ownerId: windowOwnerId)
    }

    func loadDocument() {
        // Start GRDB ValueObservation — fires immediately with existing messages,
        // then re-fires any time the messages table changes for this session.
        // No timer, no polling, no accumulation.
        guard messageObservation == nil else { return }

        // Remove old notification observers before re-registering to prevent
        // accumulation during rapid branch navigation or error-retry paths.
        if let obs = externalSourceObserver { NotificationCenter.default.removeObserver(obs); externalSourceObserver = nil }
        if let obs = mobileStreamTokenObserver { NotificationCenter.default.removeObserver(obs); mobileStreamTokenObserver = nil }
        if let obs = mobileStreamCompleteObserver { NotificationCenter.default.removeObserver(obs); mobileStreamCompleteObserver = nil }
        if let obs = streamRecoveryObserver { NotificationCenter.default.removeObserver(obs); streamRecoveryObserver = nil }
        if let obs = activeStreamStartObserver { NotificationCenter.default.removeObserver(obs); activeStreamStartObserver = nil }
        if let obs = activeStreamCompleteObserver { NotificationCenter.default.removeObserver(obs); activeStreamCompleteObserver = nil }
        // Restore any in-progress draft from before this branch was last left
        if let saved = UserDefaults.standard.string(forKey: "draft.\(branchId)"), !saved.isEmpty {
            currentInput = saved
        }
        refreshRecoveryStatus()
        guard let dbPool = DatabaseManager.shared.dbPool else {
            // Database not ready yet (app cold start — child .onAppear fires before
            // WorldTreeApp.onAppear calls setupDatabase). Retry shortly.
            guard loadRetryCount < 10 else {
                wtLog("[DocumentEditor] DB not ready after 10 retries — giving up")
                errorMessage = "Database connection failed. Try restarting the app."
                return
            }
            loadRetryCount += 1
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                self?.loadDocument()
            }
            return
        }
        loadRetryCount = 0  // reset on success

        let sid = sessionId  // capture value type, not self
        let limit = pageSize

        // trackingConstantRegion: observed tables (messages, canvas_branches) are fixed
        // regardless of data values. Enables concurrent reader execution on DatabasePool
        // that doesn't block writes — critical during streaming when tokens arrive rapidly.
        let observation = ValueObservation.trackingConstantRegion { db -> [Message] in
            // Load the LATEST pageSize messages, sorted oldest→newest for display.
            // Using a subquery so we get the tail (newest) not the head (oldest),
            // which means long conversations still show current context.
            // Pagination via "Load earlier" handles the older messages separately.
            let sql = """
                SELECT * FROM (
                    SELECT m.*,
                        (SELECT COUNT(*) FROM canvas_branches cb
                         WHERE cb.fork_from_message_id = m.id) as has_branches
                    FROM messages m
                    WHERE m.session_id = ?
                    ORDER BY m.timestamp DESC
                    LIMIT \(limit)
                ) sub ORDER BY sub.timestamp ASC
                """
            return try Message.fetchAll(db, sql: sql, arguments: [sid])
        }

        messageObservation = observation.start(
            in: dbPool,
            scheduling: .async(onQueue: .main),
            onError: { [weak self] error in
                wtLog("[DocumentEditor] Message observation error: \(error)")
                self?.messageObservation = nil
                self?.usePollingFallback = true  // observation failed — re-enable polling
                // Schedule re-subscription — transient DB errors shouldn't kill observation permanently
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    self?.loadDocument()  // guard messageObservation == nil makes this safe
                }
            },
            onChange: { [weak self] messages in
                self?.usePollingFallback = false  // observation healthy — suppress polling
                self?.applyMessages(messages)
            }
        )

        // Poll for external writes — the cortana daemon is a separate process,
        // so GRDB's ValueObservation (which only fires for writes through this pool)
        // can't see those changes. A 2s timer bridges the gap.
        startExternalRefreshTimer()

        // Restore typing indicator when navigating back to a branch with an active stream.
        // ActiveStreamRegistry owns the Task independent of any ViewModel lifecycle.
        // Re-subscribe here so this ViewModel receives future events and shows current content.
        attachToActiveStreamIfNeeded()

        // Listen for external message sources (e.g. Telegram → 📱 indicator)
        externalSourceObserver = NotificationCenter.default.addObserver(
            forName: .canvasServerExternalMessage,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let info = note.userInfo,
                      let source = info["source"] as? String,
                      let noteSessionId = info["sessionId"] as? String,
                      noteSessionId == sid,
                      source == "telegram"
                else { return }

                // Mark the last user section as telegram-sourced
                if let idx = self.document.sections.lastIndex(where: {
                    if case .user = $0.author { return true }
                    return false
                }) {
                    self.document.sections[idx].source = "telegram"
                }
            }
        }

        // Live token stream from mobile send_message — mirrors the same streaming UI
        // as locally-typed messages when a response is triggered from the iOS app.
        let bid = branchId
        mobileStreamTokenObserver = NotificationCenter.default.addObserver(
            forName: .mobileStreamToken,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let noteBranchId = note.userInfo?["branchId"] as? String,
                      noteBranchId == bid,
                      let token = note.userInfo?["token"] as? String else { return }
                self.pendingTokenBuffer += token
                if !self.isProcessing {
                    self.isProcessing = true
                    self.streamingContent = ""
                    self.startStreamBatching()
                }
            }
        }
        mobileStreamCompleteObserver = NotificationCenter.default.addObserver(
            forName: .mobileStreamComplete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let noteBranchId = note.userInfo?["branchId"] as? String,
                      noteBranchId == bid else { return }
                self.flushPendingTokens()
                self.isProcessing = false
                self.streamingContent = nil
                GlobalStreamRegistry.shared.endStream(branchId: self.branchId)
            }
        }
        streamRecoveryObserver = NotificationCenter.default.addObserver(
            forName: .streamRecoveryStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let noteSessionId = note.userInfo?["sessionId"] as? String,
                      noteSessionId == self.sessionId else { return }
                self.refreshRecoveryStatus()
                self.scheduleRecoveryCheck()
            }
        }
        activeStreamStartObserver = NotificationCenter.default.addObserver(
            forName: .activeStreamStarted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let noteBranchId = note.userInfo?["branchId"] as? String,
                      noteBranchId == self.branchId else { return }
                self.attachToActiveStreamIfNeeded()
            }
        }
        activeStreamCompleteObserver = NotificationCenter.default.addObserver(
            forName: .activeStreamComplete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let noteBranchId = note.userInfo?["branchId"] as? String,
                      noteBranchId == self.branchId else { return }
                self.activeSubscriptionId = nil
                self.refreshRecoveryStatus()
            }
        }

        // Pre-warm provider context + load branch context (treeId, parent, etc.)
        // Runs in background — doesn't block the UI.
        Task { [weak self] in
            guard let self else { return }
            do {
                if let branch = try TreeStore.shared.getBranchBySessionId(self.sessionId) {
                    self.treeId = branch.treeId
                    self.parentBranchId = branch.parentBranchId
                    self.currentBranch = branch
                    let project = (try? TreeStore.shared.getTree(branch.treeId))?.project // fire-and-forget: project name is non-critical enrichment
                    self.cachedProject = project
                    // Cache parent session ID for --fork-session / context inheritance.
                    // Done once at document open — eliminates DB reads on every send.
                    if let parentBranchId = branch.parentBranchId,
                       let parentBranch = try TreeStore.shared.getBranch(parentBranchId) {
                        self.cachedParentSessionId = parentBranch.sessionId
                    }
                    await ProviderManager.shared.activeProvider?.warmUp(
                        sessionId: self.sessionId,
                        branchId: self.branchId,
                        project: project,
                        workingDirectory: self.workingDirectory
                    )
                }
            } catch {
                wtLog("[DocumentEditor] Failed to load branch context for session \(self.sessionId): \(error)")
            }
            // Restore the most recent rotation checkpoint so the first send after
            // a restart or session reload picks up where the last session left off.
            // Without this, `checkpointContext` stays nil and we fall back to the
            // much shallower "stale session" context injection (12 turns × 500 chars).
            if let (summary, createdAt) = SessionRotator.latestCheckpoint(sessionId: self.sessionId),
               Date().timeIntervalSince(createdAt) < 259200 {  // within 72 hours
                self.checkpointContext = summary
                wtLog("[DocumentEditor] Restored rotation checkpoint from DB (\(summary.count) chars, age \(Int(Date().timeIntervalSince(createdAt)))s)")
            }
            // Schedule auto-resume evaluation after UI settles.
            // Handles two cases without any user input:
            // 1. Session had an interrupted stream recovered this launch (stream cache)
            // 2. Last DB message is from the user with no assistant reply (app quit mid-exchange)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.autoResumeIfNeeded()
            }
        }
    }

    private func scheduleRecoveryCheck(delay: Duration = .milliseconds(250)) {
        guard StreamRecoveryStore.shared.hasPendingRecovery(sessionId: sessionId) else { return }
        StreamRecoveryCoordinator.shared.scheduleRecoveryCheck(sessionId: sessionId, delay: delay)
    }

    @MainActor
    private func attachToActiveStreamIfNeeded() {
        if Self.shouldClearStaleSubscription(
            activeSubscriptionId: activeSubscriptionId,
            isStreamActive: ActiveStreamRegistry.shared.isActive(branchId)
        ) {
            activeSubscriptionId = nil
        }
        guard ActiveStreamRegistry.shared.isActive(branchId) else { return }
        guard activeSubscriptionId == nil else { return }

        isProcessing = true
        streamingContent = ActiveStreamRegistry.shared.currentContent(for: branchId) ?? ""
        startStreamBatching()
        let id = ActiveStreamRegistry.shared.subscribe(branchId: branchId) { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handleStreamEvent(event)
            }
        }
        activeSubscriptionId = id
        refreshRecoveryStatus()
    }

    static func shouldClearStaleSubscription(
        activeSubscriptionId: UUID?,
        isStreamActive: Bool
    ) -> Bool {
        activeSubscriptionId != nil && !isStreamActive
    }

    private func refreshRecoveryStatus() {
        recoveryStatusMessage = Self.recoveryStatusMessage(
            pendingRecovery: StreamRecoveryStore.shared.pendingRecovery(for: sessionId),
            hasDraft: !currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty,
            isProcessing: isProcessing,
            isStreamActive: ActiveStreamRegistry.shared.isActive(branchId)
        )
    }

    static func recoveryStatusMessage(
        pendingRecovery: PendingStreamRecovery?,
        hasDraft: Bool,
        isProcessing: Bool,
        isStreamActive: Bool
    ) -> String? {
        guard let pendingRecovery else { return nil }
        if hasDraft {
            return "Recovered response is queued until the draft is cleared."
        }
        if isProcessing || isStreamActive {
            return nil
        }
        if pendingRecovery.attemptCount >= StreamRecoveryCoordinator.autoResumeMaxAttempts {
            return "Recovered response needs a manual retry."
        }
        if pendingRecovery.lastAttemptAt != nil {
            return "Recovered response is retrying automatically."
        }
        return "Recovered response is ready to resume."
    }

    static func shouldAutoResumeUnansweredTurn(
        lastMessageRole: MessageRole?,
        messageCount: Int,
        hasCheckpointContext: Bool
    ) -> Bool {
        guard lastMessageRole == .user else { return false }
        return hasCheckpointContext || messageCount > 1
    }

    /// Automatically continue a conversation that was interrupted (crash, force-quit, or
    /// mid-exchange app close) without requiring the user to type anything.
    @MainActor
    private func autoResumeIfNeeded() async {
        guard isOwningWindow() else { return }
        refreshRecoveryStatus()

        // Don't auto-resume if the user is already typing or a stream is live.
        guard streamingContent == nil,
              currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pendingAttachments.isEmpty,
              !isProcessing,
              !isSending,
              !ActiveStreamRegistry.shared.isActive(branchId)
        else { return }

        // Case 1: stream was interrupted on a previous launch — WorldTreeApp already saved
        // the partial content to DB and registered this session for auto-resume.
        if StreamRecoveryStore.shared.hasPendingRecovery(sessionId: sessionId) {
            StreamRecoveryCoordinator.shared.scheduleRecoveryCheck(sessionId: sessionId)
            return
        }

        // Case 2: last DB message is from the user with no assistant reply —
        // app was closed between the user sending and the assistant responding.
        let messages: [Message]
        do {
            messages = try MessageStore.shared.getMessages(sessionId: sessionId)
        } catch {
            wtLog("[DocumentEditor] autoResumeIfNeeded: failed to load messages for \(sessionId): \(error)")
            return
        }
        guard let lastMsg = messages.last,
              Self.shouldAutoResumeUnansweredTurn(
                lastMessageRole: lastMsg.role,
                messageCount: messages.count,
                hasCheckpointContext: checkpointContext != nil
              ) else { return }

        wtLog("[DocumentEditor] Last message is unanswered user turn — auto-resuming session \(sessionId.prefix(8))")
        sendAutoResumeMessage("[Continuing session — please respond to the message above]")
    }

    /// Inject a system-level resume prompt and fire the LLM call.
    private func sendAutoResumeMessage(_ text: String) {
        processUserInput(
            DocumentSection(
                content: AttributedString(text),
                author: .system,
                timestamp: Date(),
                branchPoint: false,
                isEditable: false
            ),
            messageText: text
        )
    }

    /// Returns a stable UUID for a given message ID string.
    /// Message IDs from the DB are integers ("42", "123") — not valid UUID strings.
    /// We derive a deterministic UUID by hashing the ID so the same message
    /// always maps to the same UUID across render cycles, preventing view thrash.
    private func stableId(for messageId: String) -> UUID {
        if let existing = stableSectionIds[messageId] { return existing }
        // Hash the message ID string into a stable 128-bit space using a simple
        // deterministic approach: parse as integer and embed directly.
        // For integer IDs (typical DB rowids), this is always unique.
        // For UUID-format IDs, try parsing directly first.
        let id: UUID
        if let directUUID = UUID(uuidString: messageId) {
            id = directUUID
        } else if let intVal = Int64(messageId) {
            // Embed the integer in the last 8 bytes of the UUID namespace
            let hi = UInt32((intVal >> 32) & 0xFFFFFFFF)
            let lo = UInt32(intVal & 0xFFFFFFFF)
            let uuidString = String(format: "00000000-0000-4000-8000-%08X%08X", hi, lo)
            id = UUID(uuidString: uuidString) ?? UUID()
        } else {
            // Fallback: hash the string bytes
            var hash: UInt64 = 14695981039346656037
            for byte in messageId.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1099511628211
            }
            let hi = UInt32(hash >> 32)
            let lo = UInt32(hash & 0xFFFFFFFF)
            let uuidString = String(format: "00000000-0000-4000-8000-%08X%08X", hi, lo)
            id = UUID(uuidString: uuidString) ?? UUID()
        }
        stableSectionIds[messageId] = id
        return id
    }

    /// Applies the latest full message list from ValueObservation.
    /// Appends new messages and keeps hasBranches live on existing sections.
    private func applyMessages(_ messages: [Message]) {
        // Sync seenMessageIds from the current sections — closes any timing gap where
        // a section was appended directly (line 1198) but the observation fired before
        // seenMessageIds was updated (e.g. if the DB write notification arrived sooner
        // than expected). Without this, the same message could be added twice.
        for section in document.sections {
            if let msgId = section.messageId { seenMessageIds.insert(msgId) }
        }
        var newMessages: [Message] = []
        for msg in messages where !seenMessageIds.contains(msg.id) {
            // Content-based dedup: if this assistant message has the same content as what
            // we just wrote (pendingAssistantContent), it's the canvas-runner.py duplicate.
            // Mark it seen and skip — we already appended the section directly.
            if msg.role == .assistant, let pending = pendingAssistantContent, msg.content == pending {
                seenMessageIds.insert(msg.id)
                pendingAssistantContent = nil
                continue
            }
            newMessages.append(msg)
        }

        for msg in newMessages {
            let isFinding = msg.content.hasPrefix("[Finding from branch")
            let author: Author = {
                if isFinding { return .system }
                switch msg.role {
                case .user: return .user(name: "You")
                case .assistant: return .assistant
                case .system: return .system
                }
            }()

            // Pre-parse markdown once here — not on every SwiftUI render.
            // This is the expensive operation that was killing scroll performance.
            var parsed: AttributedString? = nil
            if case .assistant = author {
                parsed = Self.parseAssistantMarkdown(msg.content)
            }

            let section = DocumentSection(
                id: stableId(for: msg.id),
                content: AttributedString(msg.content),
                author: author,
                timestamp: msg.createdAt,
                branchPoint: true,
                isEditable: msg.role == .user && !isFinding,
                messageId: msg.id,
                hasBranches: msg.hasBranches,
                isFinding: isFinding,
                parsedMarkdown: parsed
            )
            document.sections.append(section)
            seenMessageIds.insert(msg.id)
        }

        // Update hasBranches on existing sections when a branch is created
        // (GRDB observation re-fires touching canvas_branches via the subquery)
        for msg in messages where seenMessageIds.contains(msg.id) && msg.hasBranches {
            let stableID = stableId(for: msg.id)
            if let idx = document.sections.firstIndex(where: { $0.id == stableID }),
               !document.sections[idx].hasBranches {
                document.sections[idx].hasBranches = true
            }
        }

        // Stop processing indicator when an assistant message arrives
        if newMessages.contains(where: { $0.role == .assistant }) {
            isProcessing = false
            GlobalStreamRegistry.shared.endStream(branchId: branchId)
        }

        refreshRecoveryStatus()
        if StreamRecoveryStore.shared.hasPendingRecovery(sessionId: sessionId) {
            scheduleRecoveryCheck()
        }

        // On first load, check if there might be older messages to paginate
        if !initialLoadComplete {
            initialLoadComplete = true
            hasMoreMessages = messages.count >= pageSize
            initialLoadDone = true  // triggers scroll-to-bottom in the view
        }
    }

    private func startExternalRefreshTimer() {
        refreshTimer?.invalidate()
        let sid = sessionId
        let limit = pageSize
        let sql = """
            SELECT * FROM (
                SELECT m.*,
                    (SELECT COUNT(*) FROM canvas_branches cb
                     WHERE cb.fork_from_message_id = m.id) as has_branches
                FROM messages m
                WHERE m.session_id = ?
                ORDER BY m.timestamp DESC
                LIMIT \(limit)
            ) sub ORDER BY sub.timestamp ASC
            """
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.usePollingFallback else { return }
                guard let dbPool = DatabaseManager.shared.dbPool else { return }
                let messages: [Message]
                do {
                    messages = try await dbPool.read({ db in
                        try Message.fetchAll(db, sql: sql, arguments: [sid])
                    })
                } catch {
                    wtLog("[DocumentEditor] Polling fallback read failed: \(error)")
                    return
                }
                self.applyMessages(messages)
            }
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)
    }

    /// Fetches the previous page of messages and prepends them to the document.
    /// Called when user scrolls to top or taps "Load earlier messages".
    func loadOlderMessages() async {
        guard let oldestMessageId = document.sections.first(where: { $0.messageId != nil })?.messageId else { return }

        let older: [Message]
        do {
            older = try MessageStore.shared.getMessagesBefore(
                sessionId: sessionId,
                beforeMessageId: oldestMessageId,
                limit: pageSize
            )
        } catch {
            wtLog("[DocumentEditor] loadOlderMessages failed: \(error)")
            hasMoreMessages = false
            return
        }
        guard !older.isEmpty else {
            hasMoreMessages = false
            return
        }

        let newSections = older.map { msg -> DocumentSection in
            let isFinding = msg.content.hasPrefix("[Finding from branch")
            let author: Author = {
                if isFinding { return .system }
                switch msg.role {
                case .user: return .user(name: "You")
                case .assistant: return .assistant
                case .system: return .system
                }
            }()
            let parsedMarkdown: AttributedString?
            if case .assistant = author {
                parsedMarkdown = Self.parseAssistantMarkdown(msg.content)
            } else {
                parsedMarkdown = nil
            }
            return DocumentSection(
                id: stableId(for: msg.id),
                content: AttributedString(msg.content),
                author: author,
                timestamp: msg.createdAt,
                branchPoint: true,
                isEditable: msg.role == .user && !isFinding,
                messageId: msg.id,
                hasBranches: msg.hasBranches,
                isFinding: isFinding,
                parsedMarkdown: parsedMarkdown
            )
        }

        for msg in older { seenMessageIds.insert(msg.id) }
        document.sections.insert(contentsOf: newSections, at: 0)

        if older.count < pageSize {
            hasMoreMessages = false
        }
    }

    func updateSection(_ sectionId: UUID, content: AttributedString) {
        guard let index = document.sections.firstIndex(where: { $0.id == sectionId }) else {
            return
        }

        document.sections[index].content = content
        document.metadata.updatedAt = Date()

        // Persist the edit to the database
        if let messageId = document.sections[index].messageId {
            MessageStore.shared.updateMessageContent(id: messageId, content: String(content.characters))
        }

        // If editing user message, potentially create a branch
        if case .user = document.sections[index].author {
            if let sectionId = document.sections.indices.contains(index) ? document.sections[index].id : nil {
                requestFork(from: sectionId)
            }
        }
    }

    /// Fork from the last message that has a messageId — used by Cmd+B / menu bar "New Branch".
    func forkFromLastMessage() {
        guard let last = document.sections.last(where: { $0.messageId != nil }) else { return }
        requestFork(from: last.id)
    }

    /// Open ForkMenu for the message at this section.
    func requestFork(from sectionId: UUID) {
        guard let section = document.sections.first(where: { $0.id == sectionId }),
              let messageId = section.messageId else { return }
        Task {
            do {
                let messages = try MessageStore.shared.getMessages(sessionId: self.sessionId)
                if let message = messages.first(where: { $0.id == messageId }) {
                    self.pendingForkMessage = message
                }
            } catch {
                wtLog("[DocumentEditor] requestFork: failed to load messages: \(error)")
            }
        }
    }

    /// Push a message from this branch up to the parent as a Finding.
    func inferFinding(from sectionId: UUID) {
        guard let section = document.sections.first(where: { $0.id == sectionId }),
              let messageId = section.messageId,
              let parentId = parentBranchId else { return }
        Task {
            do {
                try TreeStore.shared.inferFinding(
                    fromBranchId: self.branchId,
                    messageId: messageId,
                    toParentBranchId: parentId
                )
            } catch {
                wtLog("[DocumentEditor] inferFinding failed: \(error)")
            }
        }
    }

    /// One-click error recovery: inject structured error context + auto-submit.
    private func scanForFindingSignals(_ response: String) -> Bool {
        let signals = ["i found", "new approach", "this failed", "discovered", "conclusion", "the result is", "found a method", "found that", "turns out"]
        let lower = response.lowercased()
        return signals.contains { lower.contains($0) }
    }

    func fixWithClaude(_ failedCall: ToolCall) {
        let output = failedCall.output ?? "(no output)"
        currentInput = """
            Tool `\(failedCall.name)` failed.
            Input: `\(failedCall.input)`
            Error: `\(output)`

            Please diagnose and fix this.
            """
        submitInput()
    }

    /// Write a plain-text snapshot of recent turns to the checkpoint table.
    /// Called on document disappear — no API call required.
    /// Ensures cross-restart context even when context pressure never triggered a rotation.
    func writeSnapshotCheckpoint() {
        let sections = document.sections
        guard sections.count >= 2 else { return }
        let recent = Array(sections.suffix(40))
        let lines = recent.map { section -> String in
            let role: String
            switch section.author {
            case .user: role = "User"
            case .assistant: role = "Cortana"
            case .system: role = "System"
            }
            let text = String(section.content.characters.prefix(800))
            return "[\(role)]: \(text)"
        }
        let summary = "SESSION SNAPSHOT — last \(recent.count) turns before restart:\n\n"
            + lines.joined(separator: "\n\n")
        SessionRotator.writeSnapshot(
            sessionId: sessionId,
            branchId: branchId,
            summary: summary,
            messageCount: recent.count
        )
    }

    func cancelStream() {
        guard ActiveStreamRegistry.shared.isActive(branchId) else { return }

        // Grab content before cancellation so we can build the UI section below.
        let partial = ActiveStreamRegistry.shared.currentContent(for: branchId) ?? streamingContent ?? ""

        // Unsubscribe first so handleStreamEvent doesn't fire during/after cancel
        if let id = activeSubscriptionId {
            ActiveStreamRegistry.shared.unsubscribe(branchId: branchId, id: id)
            activeSubscriptionId = nil
        }

        // Registry persists partial and cleans up WakeLock / ProcessingRegistry
        ActiveStreamRegistry.shared.cancelStream(branchId: branchId)
        StreamRecoveryStore.shared.clearPending(sessionId: sessionId)

        stopStreamBatching()
        streamingContent = nil
        currentTool = nil
        isProcessing = false
        isSending = false
        appendLatestPersistedAssistantMessage(fallbackContent: partial)
        refreshRecoveryStatus()
    }

    func submitInput() {
        // Allow sending while streaming (interrupts current response) but block rapid double-sends
        // during the synchronous processUserInput setup phase (isSending is true only briefly
        // during setup, then stays true via the stream — but processUserInput handles mid-stream sends).
        guard !isSending || ActiveStreamRegistry.shared.isActive(branchId) else { return }
        let inputText = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentSnapshot = pendingAttachments
        guard !inputText.isEmpty || !attachmentSnapshot.isEmpty else { return }

        currentInput = ""
        UserDefaults.standard.removeObject(forKey: "draft.\(branchId)")
        pendingAttachments = []

        // Build display text for the section — show filename if text-only attachment
        let displayText: String
        if inputText.isEmpty && !attachmentSnapshot.isEmpty {
            displayText = attachmentSnapshot.map { "[\($0.filename)]" }.joined(separator: " ")
        } else {
            displayText = inputText
        }

        let userSection = DocumentSection(
            content: AttributedString(displayText),
            author: .user(name: "You"),
            timestamp: Date(),
            branchPoint: true,
            metadata: SectionMetadata(attachments: attachmentSnapshot.isEmpty ? nil : attachmentSnapshot),
            isEditable: true
        )

        document.sections.append(userSection)
        processUserInput(userSection, sectionUUID: userSection.id, messageText: inputText, attachments: attachmentSnapshot)
    }

    private func processUserInput(_ section: DocumentSection, sectionUUID: UUID? = nil, messageText: String? = nil, attachments: [Attachment] = []) {
        isSending = true
        if case .user = section.author {
            StreamRecoveryStore.shared.clearPending(sessionId: sessionId)
        }
        // If we're mid-stream, cancel it (registry persists partial), then proceed.
        if ActiveStreamRegistry.shared.isActive(branchId) {
            let partial = ActiveStreamRegistry.shared.currentContent(for: branchId) ?? streamingContent ?? ""

            // Unsubscribe before cancel so we don't get spurious events
            if let id = activeSubscriptionId {
                ActiveStreamRegistry.shared.unsubscribe(branchId: branchId, id: id)
                activeSubscriptionId = nil
            }

            // Stop batching timer from the interrupted stream
            stopStreamBatching()

            // Registry handles persist + WakeLock + ProcessingRegistry cleanup
            // cancelStream() persists partial to DB — do NOT persist again here (prevents duplicates)
            ActiveStreamRegistry.shared.cancelStream(branchId: branchId)
            StreamRecoveryStore.shared.clearPending(sessionId: sessionId)

            streamingContent = nil
            currentTool = nil

            if !partial.isEmpty {
                appendLatestPersistedAssistantMessage(fallbackContent: partial)
                wtLog("[DocumentEditor] Interrupted mid-stream — preserved partial response (\(partial.count) chars)")
            }
        }

        let content = messageText ?? String(section.content.characters)

        // Context state captured before the async Task
        let modelOverrideKey = "pending_model_override_\(sessionId)"
        let model = UserDefaults.standard.string(forKey: modelOverrideKey)
            ?? UserDefaults.standard.string(forKey: AppConstants.defaultModelKey)
            ?? AppConstants.defaultModel
        UserDefaults.standard.removeObject(forKey: modelOverrideKey)
        let now = Date()
        let isSessionStale = lastSendTimestamp.map {
            now.timeIntervalSince($0) > DocumentEditorViewModel.sessionStaleInterval
        } ?? true
        lastSendTimestamp = now
        let rotationCheckpoint = checkpointContext
        checkpointContext = nil
        let resolvedWorkingDir = workingDirectory ?? AppState.shared.selectedProjectPath

        // Persist user message synchronously before streaming begins
        let isNew = seenMessageIds.isEmpty
        do {
            let msg = try MessageStore.shared.sendMessage(
                sessionId: sessionId, role: .user, content: content)
            if let uuid = sectionUUID {
                stableSectionIds[msg.id] = uuid
            }
            seenMessageIds.insert(msg.id)
            if isNew {
                BranchAutoNamer.shared.autoNameIfNeeded(branchId: branchId)
            }
        } catch {
            wtLog("[DocumentEditor] Failed to persist user message: \(error)")
            errorMessage = "Failed to save message: \(error.localizedDescription)"
        }

        do {
            try MessageStore.shared.ensureSession(sessionId: sessionId, workingDirectory: workingDirectory)
        } catch {
            wtLog("[DocumentEditor] ensureSession failed for \(sessionId): \(error)")
        }

        let ctx = SendContextBuilder.build(
            message: content,
            sessionId: sessionId,
            branchId: branchId,
            model: model,
            workingDirectory: resolvedWorkingDir,
            project: cachedProject,
            checkpointContext: rotationCheckpoint,
            sections: document.sections,
            isSessionStale: isSessionStale,
            attachments: attachments
        )

        isProcessing = true
        streamingContent = ""
        startStreamBatching()
        Task { await StreamCacheManager.shared.openStreamFile(sessionId: sessionId) }

        // Start the stream first — this creates the handle synchronously (Task body is deferred).
        // Then subscribe so the handle exists to accept the subscriber.
        let subscriptionId = ActiveStreamRegistry.shared.startStream(
            branchId: branchId,
            sessionId: sessionId,
            treeId: treeId,
            projectName: cachedProject,
            stream: claudeBridge.send(context: ctx),
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in
                    await self?.handleStreamEvent(event)
                    // Release the send lock only on terminal events — prevents concurrent sends mid-stream
                    if case .done = event { self?.isSending = false }
                    if case .error = event { self?.isSending = false }
                }
            }
        )
        activeSubscriptionId = subscriptionId

        // NOTE: isSending stays true until .done/.error arrives via the subscriber above.
        // This prevents a second send from slipping through while the stream is active.
        refreshRecoveryStatus()
    }

    // MARK: - Stream Event Handler

    /// Handles BridgeEvents forwarded by ActiveStreamRegistry.
    /// Called on MainActor via the subscriber callback wrapper.
    @MainActor
    private func handleStreamEvent(_ event: BridgeEvent) async {
        switch event {
        case .text(let token):
            pendingTokenBuffer += token
            mirrorToTerminal("\u{1B}[1;37m\(token)\u{1B}[0m")

        case .thinking(let chunk):
            mirrorToTerminal("\u{1B}[2;3m\(chunk)\u{1B}[0m")

        case .toolStart(let name, let input):
            let activity = ToolActivity(name: name, input: input, status: .running)
            currentTool = activity.displayDescription
            GlobalStreamRegistry.shared.updateTool(branchId: branchId, tool: currentTool)
            let ts = Self.terminalTimestamp()
            var header = "\r\n\u{1B}[2m\u{1B}[90m─── \(ts) "
            if let parsed = activity.parsedInput {
                switch name {
                case "Bash", "bash":
                    let cmd = parsed["command"] as? String ?? ""
                    let preview = cmd.components(separatedBy: .newlines).first ?? cmd
                    let truncated = preview.count > 120 ? String(preview.prefix(120)) + "…" : preview
                    header += "\u{1B}[0m\r\n\u{1B}[1;36m  ❯ \(truncated)\u{1B}[0m"
                case "Read", "read_file":
                    let path = Self.shortenPath(parsed["file_path"] as? String ?? "file")
                    header += "\u{1B}[0m\r\n\u{1B}[33m  ◆ Read \(path)\u{1B}[0m"
                case "Edit", "edit_file":
                    let path = Self.shortenPath(parsed["file_path"] as? String ?? "file")
                    header += "\u{1B}[0m\r\n\u{1B}[32m  ◆ Edit \(path)\u{1B}[0m"
                case "Write", "write_file":
                    let path = Self.shortenPath(parsed["file_path"] as? String ?? "file")
                    header += "\u{1B}[0m\r\n\u{1B}[32m  ◆ Write \(path)\u{1B}[0m"
                case "Grep", "grep":
                    let pattern = parsed["pattern"] as? String ?? ""
                    let path = Self.shortenPath(parsed["path"] as? String ?? "")
                    header += "\u{1B}[0m\r\n\u{1B}[35m  ◆ Grep \"\(pattern)\" \(path)\u{1B}[0m"
                case "Glob", "glob":
                    let pattern = parsed["pattern"] as? String ?? ""
                    header += "\u{1B}[0m\r\n\u{1B}[35m  ◆ Glob \"\(pattern)\"\u{1B}[0m"
                case "Agent", "agent":
                    let desc = parsed["description"] as? String ?? "subagent"
                    header += "\u{1B}[0m\r\n\u{1B}[34m  ◆ Agent: \(desc)\u{1B}[0m"
                default:
                    header += "\u{1B}[0m\r\n\u{1B}[2m  ◆ \(activity.displayDescription)\u{1B}[0m"
                }
            } else {
                header += "\u{1B}[0m\r\n\u{1B}[2m  ◆ \(activity.displayDescription)\u{1B}[0m"
            }
            mirrorToTerminal(header + "\r\n")

        case .toolEnd(let name, let result, let isError):
            currentTool = nil
            GlobalStreamRegistry.shared.updateTool(branchId: branchId, tool: nil)
            if !result.isEmpty {
                let lines = result.components(separatedBy: .newlines)
                let maxLines = isError ? 20 : 15
                let previewLines = lines.prefix(maxLines)
                let indented = previewLines.map { line -> String in
                    let trimmed = line.count > 200 ? String(line.prefix(200)) + "…" : line
                    return "  \u{1B}[90m│\u{1B}[0m \u{1B}[2m\(trimmed)\u{1B}[0m"
                }.joined(separator: "\r\n")
                let overflow = lines.count > maxLines
                    ? "\r\n  \u{1B}[90m│ … \(lines.count - maxLines) more lines\u{1B}[0m" : ""
                let statusIcon = isError ? "\u{1B}[31m✗\u{1B}[0m" : "\u{1B}[32m✓\u{1B}[0m"
                mirrorToTerminal("\(indented)\(overflow)\r\n  \u{1B}[90m└─\u{1B}[0m \(statusIcon)\r\n")
            } else {
                let statusIcon = isError ? "\u{1B}[31m✗\u{1B}[0m" : "\u{1B}[32m✓\u{1B}[0m"
                mirrorToTerminal("  \u{1B}[90m└─\u{1B}[0m \(statusIcon)\r\n")
            }

        case .done(let usage):
            activeSubscriptionId = nil
            // Flush + stop batching timer before any async work
            stopStreamBatching()
            streamingContent = nil
            hasNewStreamContent = false
            currentTool = nil

            // Token accounting
            let model = UserDefaults.standard.string(forKey: AppConstants.defaultModelKey) ?? AppConstants.defaultModel
            if usage.totalInputTokens > 0 || usage.totalOutputTokens > 0 {
                let inK = String(format: "%.1f", Double(usage.totalInputTokens) / 1000.0)
                let outK = String(format: "%.1f", Double(usage.totalOutputTokens) / 1000.0)
                mirrorToTerminal("\r\n\u{1B}[90m━━━ \(inK)K in · \(outK)K out ━━━\u{1B}[0m\r\n\r\n")
                TokenStore.shared.record(
                    sessionId: sessionId,
                    branchId: branchId,
                    inputTokens: usage.totalInputTokens,
                    outputTokens: usage.totalOutputTokens,
                    cacheHitTokens: usage.cacheHitTokens,
                    model: model
                )
            }

            // The registry already persisted the response to DB.
            // Read the full content from the registry (still valid — fires before removeValue).
            let fullResponse = ActiveStreamRegistry.shared.currentContent(for: branchId) ?? ""

            // Handle empty response (CLI silent fail)
            var displayResponse = fullResponse
            if displayResponse.isEmpty {
                displayResponse = "⚠️ No response received — the session may have expired. Send another message to continue."
                wtLog("[DocumentEditor] Stream ended with no output — rotating session for recovery")
                if let cliProvider = ProviderManager.shared.activeProvider as? ClaudeCodeProvider {
                    cliProvider.rotateSession(for: sessionId)
                }
            }

            // Reload persisted section from DB — registry already wrote it
            if !displayResponse.isEmpty {
                do {
                    // Fetch the last assistant message from DB (just persisted by registry)
                    let msgs = try MessageStore.shared.getMessages(sessionId: sessionId)
                    if let lastAssistant = msgs.last(where: { $0.role == .assistant }) {
                        appendAssistantSectionIfNeeded(
                            messageId: lastAssistant.id,
                            content: lastAssistant.content,
                            timestamp: lastAssistant.createdAt,
                            hasFindingSignal: !isRootBranch && scanForFindingSignals(lastAssistant.content)
                        )
                    }
                } catch {
                    wtLog("[DocumentEditor] Failed to load persisted assistant response: \(error)")
                    appendAssistantSectionIfNeeded(
                        messageId: nil,
                        content: displayResponse,
                        timestamp: Date(),
                        hasFindingSignal: !isRootBranch && scanForFindingSignals(displayResponse)
                    )
                }
            }

            writeSnapshotCheckpoint()

            // Auto-detect decisions
            if !displayResponse.isEmpty && !displayResponse.hasPrefix("⚠️") {
                let detected = DecisionDetector.shared.detect(in: displayResponse)
                if !detected.isEmpty {
                    let novel = detected.filter {
                        !AutoDecisionStore.shared.isDuplicate(summary: $0.summary, sessionId: sessionId)
                    }
                    if !novel.isEmpty {
                        AutoDecisionStore.shared.savePending(
                            decisions: novel,
                            sessionId: sessionId,
                            branchId: branchId,
                            project: cachedProject
                        )
                        wtLog("[DocumentEditor] Auto-detected \(novel.count) decision(s) in response")
                    }
                }
            }

            // Session rotation check
            if let activeProvider = ProviderManager.shared.activeProvider {
                let allMessages: [Message]
                do {
                    allMessages = try MessageStore.shared.getMessages(sessionId: sessionId)
                } catch {
                    wtLog("[DocumentEditor] Failed to load messages for rotation check: \(error)")
                    allMessages = []
                }
                let toolCount = EventStore.shared.activityCount(branchId: branchId, minutes: 60)
                if let checkpoint = await SessionRotator.rotateIfNeeded(
                    sessionId: sessionId,
                    branchId: branchId,
                    messages: allMessages,
                    toolEventCount: toolCount,
                    provider: activeProvider
                ) {
                    checkpointContext = checkpoint
                    wtLog("[DocumentEditor] Rotation triggered — checkpoint ready for next send")
                }
            }

            // Update context cache
            let cacheLimit = await StreamCacheManager.shared.contextMessageLimit
            let cachedMsgs: [StreamCacheManager.CachedMessage] = document.sections.suffix(cacheLimit).map { sec in
                let role: String
                switch sec.author {
                case .user:      role = "user"
                case .assistant: role = "assistant"
                case .system:    role = "system"
                }
                return StreamCacheManager.CachedMessage(
                    role: role,
                    content: String(sec.content.characters),
                    timestamp: sec.timestamp
                )
            }
            await StreamCacheManager.shared.updateContextCache(sessionId: sessionId, messages: cachedMsgs)

            isProcessing = false

            // User notification when not watching
            if !displayResponse.hasPrefix("⚠️") {
                let userIsWatching = NSApp.isActive
                    && BranchWindowOwnershipRegistry.shared.hasOwner(for: branchId)
                if !userIsWatching {
                    let preview = String(displayResponse.prefix(120))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await NotificationManager.shared.notify(
                        title: "\(LocalAgentIdentity.name) is ready",
                        body: preview
                    ) }
                }
            }

            // Auto-speak
            if UserDefaults.standard.bool(forKey: AppConstants.voiceAutoSpeakKey),
               !displayResponse.hasPrefix("⚠️") {
                let speakText = displayResponse.count > 500
                    ? String(displayResponse.prefix(500)) + "..."
                    : displayResponse
                let cleanText = speakText
                    .replacingOccurrences(of: "```[\\s\\S]*?```", with: " code block ", options: .regularExpression)
                    .replacingOccurrences(of: "`[^`]+`", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "#+ ", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "**", with: "")
                let rawSpeed = UserDefaults.standard.double(forKey: AppConstants.voiceSpeedKey)
                let rawPitch = UserDefaults.standard.double(forKey: AppConstants.voicePitchKey)
                let voiceOptions = SpeechOptions(
                    speed: rawSpeed > 0 ? min(max(rawSpeed, 0.5), 2.0) : 1.0,
                    pitch: rawPitch > 0 ? min(max(rawPitch, 0.5), 2.0) : 1.0
                )
                Task { try? await VoiceService.shared.speak(cleanText, options: voiceOptions) }
            }

            BranchAutoNamer.shared.suggestRename(forBranchId: branchId)
            refreshRecoveryStatus()

        case .error(let msg):
            activeSubscriptionId = nil
            stopStreamBatching()
            streamingContent = nil
            isProcessing = false
            wtLog("[DocumentEditor] Provider error: \(msg)")
            mirrorToTerminal("\r\n\u{1B}[1;31m  ⚠ Error: \(msg)\u{1B}[0m\r\n")
            errorMessage = msg
            refreshRecoveryStatus()
        }
    }

    private func appendLatestPersistedAssistantMessage(fallbackContent: String) {
        guard !fallbackContent.isEmpty else { return }

        do {
            let msgs = try MessageStore.shared.getMessages(sessionId: sessionId)
            if let lastAssistant = msgs.last(where: { $0.role == .assistant && !seenMessageIds.contains($0.id) }) {
                appendAssistantSectionIfNeeded(
                    messageId: lastAssistant.id,
                    content: lastAssistant.content,
                    timestamp: lastAssistant.createdAt,
                    hasFindingSignal: !isRootBranch && scanForFindingSignals(lastAssistant.content)
                )
                return
            }
        } catch {
            wtLog("[DocumentEditor] Failed to load interrupted response from DB: \(error)")
        }

        appendAssistantSectionIfNeeded(
            messageId: nil,
            content: fallbackContent,
            timestamp: Date(),
            hasFindingSignal: !isRootBranch && scanForFindingSignals(fallbackContent)
        )
    }

    private func appendAssistantSectionIfNeeded(
        messageId: String?,
        content: String,
        timestamp: Date,
        hasFindingSignal: Bool = false
    ) {
        guard !content.isEmpty else { return }

        if !Self.shouldAppendAssistantSection(
            messageId: messageId,
            content: content,
            seenMessageIds: seenMessageIds,
            sections: document.sections
        ) {
            return
        }

        if let messageId {
            seenMessageIds.insert(messageId)
            pendingAssistantContent = content
        }

        let assistantSection = DocumentSection(
            id: messageId.map(stableId(for:)) ?? UUID(),
            content: AttributedString(content),
            author: .assistant,
            timestamp: timestamp,
            branchPoint: true,
            isEditable: false,
            messageId: messageId,
            hasFindingSignal: hasFindingSignal,
            parsedMarkdown: Self.parseAssistantMarkdown(content)
        )
        document.sections.append(assistantSection)
    }

    static func parseAssistantMarkdown(_ raw: String) -> AttributedString {
        (try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(raw)
    }

    static func shouldAppendAssistantSection(
        messageId: String?,
        content: String,
        seenMessageIds: Set<String>,
        sections: [DocumentSection]
    ) -> Bool {
        guard !content.isEmpty else { return false }

        if let messageId {
            if seenMessageIds.contains(messageId) { return false }
            if sections.contains(where: { $0.messageId == messageId }) { return false }
            return true
        }

        let lastAssistantContent = sections.last(where: {
            if case .assistant = $0.author { return true }
            return false
        }).map { String($0.content.characters) }
        return lastAssistantContent != content
    }

    // MARK: - Organic Branching (Phase 8)

    func analyzeForBranchOpportunities() async {
        guard !currentInput.isEmpty else {
            branchOpportunity = nil
            return
        }

        // Analyze after user pauses (debounce)
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

        // Check if input still matches (user might have kept typing)
        let analyzedText = currentInput
        guard analyzedText == currentInput else { return }

        // Detect branch opportunities
        let opportunity = await SuggestionEngine.shared.analyzeBranchOpportunity(analyzedText)
        branchOpportunity = opportunity
    }

    func acceptSuggestion(_ suggestion: BranchSuggestion) {
        wtLog("[DocumentEditor] Accepting branch suggestion: \(suggestion.title)")

        // Clear the opportunity
        branchOpportunity = nil

        // Notify parent to create branch
        parentBranchLayout?.createBranchFromSuggestion(suggestion, userInput: currentInput)

        // Clear input
        currentInput = ""
    }

    func spawnParallelBranches() {
        guard let opportunity = branchOpportunity else { return }

        wtLog("[DocumentEditor] Spawning \(opportunity.suggestions.count) parallel branches")

        // Clear the opportunity
        branchOpportunity = nil

        // Notify parent to create multiple branches
        parentBranchLayout?.spawnParallelBranches(opportunity.suggestions, userInput: currentInput)

        // Clear input
        currentInput = ""
    }

}

// MARK: - Empty Conversation State

struct EmptyConversationView: View {
    var body: some View {
        VStack(spacing: 16) {
            AuthorIndicator(author: .assistant)
                .frame(width: 48, height: 48)

            Text("Start a conversation")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Ask anything — \(LocalAgentIdentity.name) has full access to your project files,\nterminal, and knowledge base.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .padding()
    }
}

// MARK: - Conversation Search Bar

/// Slim search bar that slides in at the top of the conversation when ⌘F is pressed.
/// Dims non-matching messages; Escape dismisses.
struct ConversationSearchBar: View {
    @Binding var query: String
    let matchCount: Int
    let onDismiss: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("Find in conversation…", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFocused)
                .onSubmit { onDismiss() }

            if !query.isEmpty {
                Text("\(matchCount) \(matchCount == 1 ? "match" : "matches")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut(duration: 0.15), value: matchCount)

                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button("Done") { onDismiss() }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.blue)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onAppear { isFocused = true }
    }
}

// MARK: - Thinking Indicator (3-dot animation)

struct ThinkingIndicatorView: View {
    var toolDescription: String? = nil

    /// Captured at view creation so elapsed time is always relative to when
    /// this particular thinking phase started — not relative to app launch.
    @State private var startedAt = Date()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.teal.gradient)
                .frame(width: 32, height: 32)
                .overlay {
                    Text(LocalAgentIdentity.initial)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 2) {
                // Unified TimelineView: drives both the dot animation AND the elapsed counter.
                // Updates every 0.4s — fast enough for smooth dots, slow enough to be cheap.
                TimelineView(.periodic(from: Date(), by: 0.4)) { context in
                    let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3
                    let elapsed = Int(context.date.timeIntervalSince(startedAt))
                    HStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(Color.teal)
                                .frame(width: 7, height: 7)
                                .opacity(phase == i ? 1.0 : 0.3)
                                .scaleEffect(phase == i ? 1.2 : 0.8)
                                .animation(.easeInOut(duration: 0.25), value: phase)
                        }
                        // Show elapsed time after 3s so brief responses don't flicker a counter
                        if elapsed >= 3 {
                            Text(elapsed < 60 ? "\(elapsed)s" : "\(elapsed / 60)m \(elapsed % 60)s")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.teal.opacity(0.4))
                                .transition(.opacity)
                        }
                    }
                    .padding(.top, 12)
                }

                if let description = toolDescription {
                    Text(description)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.teal.opacity(0.5))
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Live Streaming Section

struct StreamingSectionView: View {
    let content: String
    private static let markdownCueCharacters = CharacterSet(charactersIn: "`*_#[]-\n>:")

    /// Cached parse result — only recomputed when content crosses a re-parse threshold.
    /// During streaming at 10fps, every body evaluation was re-parsing the entire accumulated
    /// string through AttributedString(markdown:) AND then re-parsing each prose segment inside
    /// MarkdownCodeFenceView. This cache skips re-parsing until content grows by 80+ characters
    /// or a code fence boundary changes, cutting markdown parse work by ~90% during streaming.
    @State private var cachedRaw: String = ""
    @State private var cachedRendered: AttributedString = AttributedString("")

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.teal.gradient)
                .frame(width: 32, height: 32)
                .overlay {
                    Text(LocalAgentIdentity.initial)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 8) {
                markdownContent
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Pulsing cursor — scale + glow animation signals active generation
                PulsingCursor()
            }
            .padding(.vertical, 8)

            Spacer()
        }
        .padding(.horizontal, 0)
        .onChange(of: content) { _, newContent in
            updateCacheIfNeeded(newContent)
        }
        .onAppear {
            updateCacheIfNeeded(content)
        }
    }

    /// Re-parse only when content has grown significantly or a structural boundary changed.
    /// "Significant" = 80+ new characters OR a new/closed code fence since last parse.
    private func updateCacheIfNeeded(_ newContent: String) {
        guard !newContent.isEmpty else { return }
        guard Self.shouldRefreshMarkdownCache(previous: cachedRaw, new: newContent) else { return }

        cachedRaw = newContent
        cachedRendered = (try? AttributedString(
            markdown: newContent,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full
            )
        )) ?? AttributedString(newContent)
    }

    static func shouldRefreshMarkdownCache(previous: String, new: String) -> Bool {
        guard !new.isEmpty else { return false }
        guard !previous.isEmpty else { return true }
        guard new != previous else { return false }
        guard new.count >= previous.count, new.hasPrefix(previous) else { return true }

        let delta = new.count - previous.count
        let fenceCountChanged = new.components(separatedBy: "```").count
            != previous.components(separatedBy: "```").count
        if fenceCountChanged || delta >= 10 {
            return true
        }

        let appended = String(new.dropFirst(previous.count))
        return appended.unicodeScalars.contains { Self.markdownCueCharacters.contains($0) }
    }

    @ViewBuilder
    private var markdownContent: some View {
        if content.isEmpty {
            Text(" ")
        } else if cachedRaw == content {
            // Cache is current — use pre-parsed result
            MarkdownCodeFenceView(raw: cachedRaw, rendered: cachedRendered)
        } else {
            // Cache is stale but below re-parse threshold — show raw text with
            // the cached rendered base. The tail (new tokens since last parse)
            // renders as plain text until the next cache refresh.
            MarkdownCodeFenceView(raw: content, rendered: cachedRendered)
        }
    }
}

/// Pulsing vertical bar cursor — scales and glows in sync to signal live generation.
struct PulsingCursor: View {
    @State private var scaleY: CGFloat = 1.0
    @State private var opacity: Double = 1.0
    @State private var glowRadius: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.cyan)
            .frame(width: 2.5, height: 16)
            .scaleEffect(y: scaleY, anchor: .bottom)
            .opacity(opacity)
            .shadow(color: Color.cyan.opacity(0.7), radius: glowRadius)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    scaleY = 0.65
                    opacity = 0.35
                    glowRadius = 5
                }
            }
    }
}

/// Legacy alias kept so nothing else breaks if it referenced BlinkingCursor.
typealias BlinkingCursor = PulsingCursor

// MARK: - Scroll To Bottom FAB

/// Floating action button shown when the user has scrolled up while new tokens are streaming.
struct ScrollToBottomFAB: View {
    let action: () -> Void
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.0

    var body: some View {
        Button(action: action) {
            ZStack {
                // Pulsing ring behind the button
                Circle()
                    .strokeBorder(Color.cyan.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 42, height: 42)
                    .scaleEffect(pulseScale)
                    .opacity(pulseOpacity)

                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.cyan)
                    .shadow(color: Color.cyan.opacity(0.5), radius: 6)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                pulseScale = 1.7
                pulseOpacity = 0
            }
        }
    }
}

// MARK: - User Input Area

struct UserInputArea: View {
    @Binding var text: String
    @Binding var attachments: [Attachment]
    let isProcessing: Bool
    let onSubmit: () -> Void
    var onCancel: (() -> Void)?
    var onTabKey: (() -> Bool)?
    var onShiftTabKey: (() -> Bool)?
    var onCmdReturnKey: (() -> Bool)?

    @FocusState private var editorFocused: Bool
    @State private var isDragTargeted = false
    @State private var isListening = false
    @State private var liveTranscription = ""
    @State private var editorContentHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    // Attachment tray — shown above the text field when attachments exist
                    if !attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(attachments) { attachment in
                                    AttachmentChip(attachment: attachment) {
                                        attachments.removeAll { $0.id == attachment.id }
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 72)
                    }

                    ZStack(alignment: .topLeading) {
                        if text.isEmpty && attachments.isEmpty {
                            Text("Message \(LocalAgentIdentity.name)… or drop images/files here")
                                .font(.system(.body))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        } else if text.isEmpty {
                            Text("Add a message…")
                                .font(.system(.body))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }

                        KeyboardHandlingTextEditor(
                            text: $text,
                            contentHeight: $editorContentHeight,
                            onTabKey: onTabKey,
                            onShiftTabKey: onShiftTabKey,
                            onCmdReturnKey: onCmdReturnKey,
                            onSubmit: {
                                let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                if hasContent || !attachments.isEmpty { onSubmit() }
                            }
                        )
                        .focused($editorFocused)
                    }
                    .frame(height: min(max(44, editorContentHeight), 160))
                    .background(isDragTargeted
                        ? Color.accentColor.opacity(0.08)
                        : Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isDragTargeted ? Color.accentColor.opacity(0.8) :
                                    editorFocused ? Color.accentColor.opacity(0.5) :
                                    Color(nsColor: .separatorColor),
                                lineWidth: isDragTargeted || editorFocused ? 2 : 1
                            )
                    )
                    .onDrop(of: [.fileURL, .image, .png, .jpeg, .tiff, .pdf],
                            isTargeted: $isDragTargeted) { providers in
                        handleDrop(providers: providers)
                        return true
                    }
                    .background(
                        PasteImageListener { imageData in
                            attachments.append(Attachment.from(imageData: imageData))
                        }
                    )

                    // Live transcription preview while listening
                    if isListening && !liveTranscription.isEmpty {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                            Text(liveTranscription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.05))
                        .cornerRadius(4)
                        .transition(.opacity)
                    }

                    HStack {
                        if !text.isEmpty {
                            Text("\(text.count)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(text.count > 8000 ? Color.red : Color.secondary.opacity(0.4))
                        }

                        Button { pickFiles() } label: {
                            Image(systemName: "paperclip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Attach file or image (⌘V to paste image)")

                        // Mic button — tap to dictate into the text field
                        Button { toggleVoiceInput() } label: {
                            Image(systemName: isListening ? "mic.fill" : "mic")
                                .font(.caption)
                                .foregroundStyle(isListening ? .red : .secondary)
                                .symbolEffect(.variableColor.iterative, isActive: isListening)
                        }
                        .buttonStyle(.plain)
                        .help(isListening ? "Stop listening" : "Voice input")

                        Spacer()

                        if isProcessing {
                            Button(action: { onCancel?() }) {
                                Label("Stop", systemImage: "stop.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        } else {
                            Button(action: onSubmit) {
                                Label("Send", systemImage: "paperplane.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
                            )
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: VoiceService.transcriptionUpdated)) { notification in
            guard let transcribedText = notification.userInfo?["text"] as? String else { return }
            let isFinal = notification.userInfo?["isFinal"] as? Bool ?? false
            liveTranscription = transcribedText
            if isFinal {
                // Append final transcription to input field
                if text.isEmpty {
                    text = transcribedText
                } else {
                    text += " " + transcribedText
                }
                liveTranscription = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: VoiceService.listeningStateChanged)) { notification in
            isListening = notification.userInfo?["isListening"] as? Bool ?? false
        }
    }

    private func toggleVoiceInput() {
        if isListening {
            Task { await VoiceService.shared.stopListening() }
        } else {
            liveTranscription = ""
            Task {
                let granted = await VoiceService.shared.requestPermissions()
                guard granted else { return }
                do {
                    try await VoiceService.shared.startListening()
                } catch {
                    wtLog("[VoiceInput] Failed to start: \(error)")
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          let attachment = Attachment.from(url: url) else { return }
                    DispatchQueue.main.async { self.attachments.append(attachment) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage,
                          let tiff = image.tiffRepresentation,
                          let bmp = NSBitmapImageRep(data: tiff),
                          let png = bmp.representation(using: .png, properties: [:]) else { return }
                    let attachment = Attachment.from(imageData: png)
                    DispatchQueue.main.async { self.attachments.append(attachment) }
                }
            }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf, .plainText, .sourceCode, .data]
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let attachment = Attachment.from(url: url) { attachments.append(attachment) }
            }
        }
    }
}

// MARK: - Attachment Chip

struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if attachment.type == .image, let img = attachment.nsImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipped()
                    .cornerRadius(6)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 56, height: 56)
                    .overlay {
                        VStack(spacing: 2) {
                            Image(systemName: attachment.type.systemImage)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Text(attachment.filename)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 2)
                        }
                    }
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.5))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
    }
}

// MARK: - Clipboard Image Paste Listener

/// Transparent NSView that intercepts ⌘V and extracts images from the pasteboard.
struct PasteImageListener: NSViewRepresentable {
    let onPaste: (Data) -> Void

    func makeNSView(context: Context) -> PasteListenerView {
        let view = PasteListenerView()
        view.onPaste = onPaste
        return view
    }

    func updateNSView(_ nsView: PasteListenerView, context: Context) {
        nsView.onPaste = onPaste
    }
}

final class PasteListenerView: NSView {
    var onPaste: ((Data) -> Void)?
    override var acceptsFirstResponder: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "v" {
            let pb = NSPasteboard.general
            if let img = NSImage(pasteboard: pb),
               let tiff = img.tiffRepresentation,
               let bmp = NSBitmapImageRep(data: tiff),
               let png = bmp.representation(using: .png, properties: [:]) {
                onPaste?(png)
                return
            }
        }
        super.keyDown(with: event)
    }
}

// MARK: - Scroll Bottom Tracker

/// ViewModifier that tracks whether the scroll view is near the bottom.
/// Uses `onScrollGeometryChange` on macOS 15+ and a no-op on earlier versions.
private struct ScrollBottomTracker: ViewModifier {
    @Binding var isScrolledToBottom: Bool
    @Binding var hasNewStreamContent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self, of: { geo in
                    let distanceFromBottom = geo.contentSize.height
                        - geo.contentOffset.y
                        - geo.containerSize.height
                    return distanceFromBottom < 80
                }) { _, atBottom in
                    isScrolledToBottom = atBottom
                    if atBottom { hasNewStreamContent = false }
                }
        } else {
            // macOS 14: no scroll geometry API — always report scrolled to bottom.
            content.onAppear { isScrolledToBottom = true }
        }
    }
}
