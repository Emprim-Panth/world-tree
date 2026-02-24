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
    @State private var isAtBottom = true
    @State private var hasNewMessages = false

    var parentBranchLayout: BranchLayoutViewModel?

    init(sessionId: String,
         branchId: String,
         workingDirectory: String,
         parentBranchLayout: BranchLayoutViewModel? = nil) {
        self.parentBranchLayout = parentBranchLayout
        _viewModel = StateObject(wrappedValue: DocumentEditorViewModel(
            sessionId: sessionId,
            branchId: branchId,
            workingDirectory: workingDirectory
        ))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Empty state — shown before the first message
                        if viewModel.document.sections.isEmpty && !viewModel.isProcessing {
                            EmptyConversationView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                        }

                        // Document sections (replaces message bubbles)
                        ForEach(viewModel.document.sections) { section in
                            DocumentSectionView(
                                section: section,
                                isHovered: hoveredSectionId == section.id,
                                showInferButton: !viewModel.isRootBranch,
                                onEdit: { newContent in
                                    viewModel.updateSection(section.id, content: newContent)
                                },
                                onBranch: {
                                    viewModel.requestFork(from: section.id)
                                },
                                onInfer: {
                                    viewModel.inferFinding(from: section.id)
                                },
                                onNavigateToBranch: { branchId in
                                    guard let treeId = viewModel.treeId else { return }
                                    AppState.shared.selectBranch(branchId, in: treeId)
                                },
                                onFixError: { failedCall in
                                    viewModel.fixWithClaude(failedCall)
                                }
                            )
                            .id(section.id)
                            .onHover { hovering in
                                hoveredSectionId = hovering ? section.id : nil
                            }
                            .opacity(searchQuery.isEmpty ? 1.0 :
                                (String(section.content.characters)
                                    .localizedCaseInsensitiveContains(searchQuery) ? 1.0 : 0.3))
                        }

                        // Live streaming section — tokens appear as they arrive (only once content exists)
                        if let streaming = viewModel.streamingContent, !streaming.isEmpty {
                            StreamingSectionView(content: streaming)
                                .id("streaming")
                        }

                        // Thinking indicator — shows until first token arrives
                        if viewModel.isProcessing && (viewModel.streamingContent == nil || viewModel.streamingContent == "") {
                            ThinkingIndicatorView(toolDescription: viewModel.currentTool)
                                .id("thinking")
                                .padding(.horizontal, 0)
                                .padding(.vertical, 8)
                        }

                        // User input area (always at bottom)
                        Divider()
                            .padding(.vertical, 16)

                        VStack(alignment: .leading, spacing: 8) {
                            UserInputArea(
                                text: $viewModel.currentInput,
                                attachments: $viewModel.pendingAttachments,
                                isProcessing: viewModel.isProcessing,
                                onSubmit: { viewModel.submitInput() },
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

                            // Branch suggestions — appear below the input as compact chips
                            if let opportunity = viewModel.branchOpportunity {
                                BranchSuggestionChips(
                                    suggestions: opportunity.suggestions,
                                    selectedIndex: selectedSuggestionIndex,
                                    onAccept: { suggestion in
                                        viewModel.acceptSuggestion(suggestion)
                                    },
                                    onAcceptAll: {
                                        viewModel.spawnParallelBranches()
                                    },
                                    onDismiss: {
                                        viewModel.branchOpportunity = nil
                                    }
                                )
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                        .padding(.bottom, 24)

                        // Scroll anchor — tracks whether user is near bottom
                        Color.clear.frame(height: 1).id("scroll-bottom")
                            .onAppear { isAtBottom = true; hasNewMessages = false }
                            .onDisappear { isAtBottom = false }
                    }
                    .padding(.horizontal, max(24, (geometry.size.width - 800) / 2))
                    .padding(.vertical, 24)
                    .environment(\.conversationHPad, max(24, (geometry.size.width - 800) / 2))
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if showSearch {
                        ConversationSearchBar(query: $searchQuery, onDismiss: {
                            showSearch = false
                            searchQuery = ""
                            isFocused = true
                        })
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: showSearch)
                .overlay(alignment: .bottom) {
                    // Floating scroll-to-bottom — appears when user scrolls up
                    if !isAtBottom {
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo("scroll-bottom", anchor: .bottom)
                            }
                            hasNewMessages = false
                        } label: {
                            HStack(spacing: 6) {
                                if hasNewMessages {
                                    Circle()
                                        .fill(Color.cyan)
                                        .frame(width: 8, height: 8)
                                    Text("New messages")
                                        .font(.caption)
                                }
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, hasNewMessages ? 14 : 10)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isAtBottom)
                .background(Color(nsColor: .textBackgroundColor))
                .onAppear {
                    isFocused = true
                    viewModel.loadDocument()
                    viewModel.parentBranchLayout = parentBranchLayout
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
                        }
                    )
                }
                // Unified scroll handler — only auto-scrolls when user is at the bottom.
                // If the user scrolled up to read, we show a "new messages" indicator instead.
                .onChange(of: viewModel.document.sections.count) { _, _ in
                    guard viewModel.streamingContent == nil, !viewModel.isProcessing else { return }
                    if isAtBottom {
                        proxy.scrollTo("scroll-bottom")
                    } else {
                        hasNewMessages = true
                    }
                }
                .onChange(of: viewModel.streamingContent) { _, content in
                    if content != nil {
                        // Only auto-scroll while streaming if user hasn't scrolled up
                        if viewModel.isScrolledToBottom {
                            proxy.scrollTo("scroll-bottom")
                        }
                    } else {
                        // Streaming ended — snap to bottom so input is in view
                        proxy.scrollTo("scroll-bottom")
                        viewModel.hasNewStreamContent = false
                    }
                }
                // Track scroll position — inhibit auto-scroll when user scrolled up
                // onScrollGeometryChange requires macOS 15.0+
                .modifier(ScrollBottomTracker(isScrolledToBottom: $viewModel.isScrolledToBottom,
                                             hasNewStreamContent: $viewModel.hasNewStreamContent))
                // "Scroll to bottom" FAB — appears when streaming with user scrolled up
                .overlay(alignment: .bottomTrailing) {
                    if viewModel.hasNewStreamContent && !viewModel.isScrolledToBottom {
                        ScrollToBottomFAB {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                proxy.scrollTo("scroll-bottom")
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
                    if processing && viewModel.streamingContent == nil && isAtBottom {
                        proxy.scrollTo("scroll-bottom")
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
            }
        }
    }
}

@MainActor
class DocumentEditorViewModel: ObservableObject {
    @Published var document: ConversationDocument
    private var branchAnalysisTask: Task<Void, Never>?
    @Published var currentInput = "" {
        didSet {
            branchAnalysisTask?.cancel()
            branchAnalysisTask = Task { await analyzeForBranchOpportunities() }
        }
    }
    @Published var pendingAttachments: [Attachment] = []
    @Published var isProcessing = false
    @Published var branchOpportunity: BranchOpportunity?
    /// Live token stream content — shown in the chat as Cortana types.
    /// Nil when not streaming; cleared once the full response is persisted.
    @Published var streamingContent: String?
    /// Currently running tool name — shown in the thinking indicator so Evan knows I'm working, not frozen.
    @Published var currentTool: String?

    @Published var pendingForkMessage: Message?

    /// Message IDs from external sources (e.g. Telegram) — shown with 📱 indicator
    private var externalSourceMessages: Set<String> = []
    private var externalSourceObserver: NSObjectProtocol?

    /// Whether the conversation scroll view is at (or near) the bottom.
    /// False when the user has manually scrolled up — suppresses auto-scroll.
    @Published var isScrolledToBottom = true

    /// True when new streaming tokens arrived while the user was scrolled up.
    /// Drives the "scroll to bottom" FAB visibility.
    @Published var hasNewStreamContent = false

    // MARK: - 60fps Token Batching (CADisplayLink-equivalent via main-RunLoop Timer)

    /// Accumulated tokens since the last frame flush.
    /// Written per-token; flushed to streamingContent at ~60fps by streamFlushTimer.
    private var pendingTokenBuffer = ""

    /// Fires at 60fps on the main RunLoop to flush pendingTokenBuffer → streamingContent.
    /// Using a Timer keyed to .common run-loop mode ensures it fires even during scroll tracking.
    private var streamFlushTimer: Timer?

    private func startStreamBatching() {
        guard streamFlushTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingTokens() }
        }
        RunLoop.main.add(timer, forMode: .common)
        streamFlushTimer = timer
    }

    private func stopStreamBatching() {
        streamFlushTimer?.invalidate()
        streamFlushTimer = nil
        flushPendingTokens()  // drain any remaining tokens
    }

    /// Drain accumulated tokens to streamingContent — called at 60fps.
    private func flushPendingTokens() {
        guard !pendingTokenBuffer.isEmpty else { return }
        let chunk = pendingTokenBuffer
        pendingTokenBuffer = ""
        streamingContent = (streamingContent ?? "") + chunk
        if !isScrolledToBottom { hasNewStreamContent = true }
    }

    private let sessionId: String
    private let branchId: String
    private let workingDirectory: String
    private var cachedProject: String?
    /// Parent branch's session ID — loaded once at document open for --fork-session support.
    private var cachedParentSessionId: String?
    private var seenMessageIds: Set<String> = []
    private(set) var treeId: String?
    private(set) var parentBranchId: String?
    private(set) var currentBranch: Branch?
    var isRootBranch: Bool { parentBranchId == nil }

    /// Timestamp of the last successful send — used to detect stale CLI sessions.
    /// nil = no send yet this launch (treat as stale).
    private var lastSendTimestamp: Date?
    private static let sessionStaleInterval: TimeInterval = 15 * 60  // 15 min
    /// Stable UUID per message ID — prevents random UUIDs being generated each
    /// render cycle when msg.id is an integer string (not a UUID string).
    private var stableSectionIds: [String: UUID] = [:]
    /// GRDB ValueObservation cancellable — auto-cancels when view model is deallocated.
    private var messageObservation: AnyDatabaseCancellable?
    /// Reference to the active streaming task — allows cancellation when user interrupts.
    private var streamTask: Task<Void, Never>?
    /// Routes messages through Friday daemon when available, falls back to ProviderManager.
    private let claudeBridge = ClaudeBridge()
    weak var parentBranchLayout: BranchLayoutViewModel?

    deinit {
        if let observer = externalSourceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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

    func loadDocument() {
        // Start GRDB ValueObservation — fires immediately with existing messages,
        // then re-fires any time the messages table changes for this session.
        // No timer, no polling, no accumulation.
        guard messageObservation == nil else { return }
        guard let dbPool = DatabaseManager.shared.dbPool else {
            // Database not ready yet (app cold start — child .onAppear fires before
            // WorldTreeApp.onAppear calls setupDatabase). Retry shortly.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                self?.loadDocument()
            }
            return
        }

        let sid = sessionId  // capture value type, not self

        let observation = ValueObservation.tracking { db -> [Message] in
            let sql = """
                SELECT m.*,
                    (SELECT COUNT(*) FROM canvas_branches cb
                     WHERE cb.fork_from_message_id = m.id) as has_branches
                FROM messages m
                WHERE m.session_id = ?
                ORDER BY m.timestamp ASC
                LIMIT 500
                """
            return try Message.fetchAll(db, sql: sql, arguments: [sid])
        }

        messageObservation = observation.start(
            in: dbPool,
            scheduling: .async(onQueue: .main),
            onError: { [weak self] error in
                print("[DocumentEditor] Message observation error: \(error)")
                self?.messageObservation = nil
            },
            onChange: { [weak self] messages in
                self?.applyMessages(messages)
            }
        )

        // Listen for external message sources (e.g. Telegram → 📱 indicator)
        if externalSourceObserver == nil {
            let sid = sessionId
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
        }

        // Pre-warm provider context + load branch context (treeId, parent, etc.)
        // Runs in background — doesn't block the UI.
        Task { [weak self] in
            guard let self else { return }
            if let branch = try? TreeStore.shared.getBranchBySessionId(self.sessionId) {
                self.treeId = branch.treeId
                self.parentBranchId = branch.parentBranchId
                self.currentBranch = branch
                let project = (try? TreeStore.shared.getTree(branch.treeId))?.project
                self.cachedProject = project
                // Cache parent session ID for --fork-session / context inheritance.
                // Done once at document open — eliminates DB reads on every send.
                if let parentBranchId = branch.parentBranchId,
                   let parentBranch = try? TreeStore.shared.getBranch(parentBranchId) {
                    self.cachedParentSessionId = parentBranch.sessionId
                }
                await ProviderManager.shared.activeProvider?.warmUp(
                    sessionId: self.sessionId,
                    branchId: self.branchId,
                    project: project,
                    workingDirectory: self.workingDirectory
                )
            }
        }
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
        let newMessages = messages.filter { !seenMessageIds.contains($0.id) }

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

            let section = DocumentSection(
                id: stableId(for: msg.id),
                content: AttributedString(msg.content),
                author: author,
                timestamp: msg.createdAt,
                branchPoint: true,
                isEditable: msg.role == .user && !isFinding,
                messageId: msg.id,
                hasBranches: msg.hasBranches,
                isFinding: isFinding
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
        }
    }

    func updateSection(_ sectionId: UUID, content: AttributedString) {
        guard let index = document.sections.firstIndex(where: { $0.id == sectionId }) else {
            return
        }

        document.sections[index].content = content
        document.metadata.updatedAt = Date()

        // If editing user message, potentially create a branch
        if case .user = document.sections[index].author {
            // TODO: Implement automatic branching on edit
        }
    }

    /// Open ForkMenu for the message at this section.
    func requestFork(from sectionId: UUID) {
        guard let section = document.sections.first(where: { $0.id == sectionId }),
              let messageId = section.messageId else { return }
        Task {
            let messages = (try? MessageStore.shared.getMessages(sessionId: self.sessionId)) ?? []
            if let message = messages.first(where: { $0.id == messageId }) {
                self.pendingForkMessage = message
            }
        }
    }

    /// Push a message from this branch up to the parent as a Finding.
    func inferFinding(from sectionId: UUID) {
        guard let section = document.sections.first(where: { $0.id == sectionId }),
              let messageId = section.messageId,
              let parentId = parentBranchId else { return }
        Task {
            try? TreeStore.shared.inferFinding(
                fromBranchId: self.branchId,
                messageId: messageId,
                toParentBranchId: parentId
            )
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

    func submitInput() {
        let inputText = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentSnapshot = pendingAttachments
        guard !inputText.isEmpty || !attachmentSnapshot.isEmpty else { return }

        currentInput = ""
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
        // If we're mid-stream, persist the partial response before starting the new one.
        // This prevents the streaming text from vanishing when the user interrupts.
        if let partialContent = streamingContent, !partialContent.isEmpty {
            streamTask?.cancel()
            streamTask = nil

            let partial = partialContent
            streamingContent = nil
            currentTool = nil

            // Persist the interrupted response as a completed section
            do {
                let msg = try MessageStore.shared.sendMessage(
                    sessionId: sessionId, role: .assistant, content: partial)
                seenMessageIds.insert(msg.id)
                let interruptedSection = DocumentSection(
                    id: stableId(for: msg.id),
                    content: AttributedString(partial),
                    author: .assistant,
                    timestamp: msg.createdAt,
                    branchPoint: true,
                    isEditable: false,
                    messageId: msg.id
                )
                document.sections.append(interruptedSection)
            } catch {
                canvasLog("[DocumentEditor] Failed to persist interrupted response: \(error)")
                let interruptedSection = DocumentSection(
                    content: AttributedString(partial),
                    author: .assistant,
                    timestamp: Date(),
                    branchPoint: true,
                    isEditable: false
                )
                document.sections.append(interruptedSection)
            }

            // Close the crash-recovery stream file for the interrupted response
            Task { await StreamCacheManager.shared.closeStream(sessionId: sessionId) }

            canvasLog("[DocumentEditor] Interrupted mid-stream — preserved partial response (\(partial.count) chars)")
        } else if streamTask != nil {
            // Processing but no content yet (thinking state) — just cancel
            streamTask?.cancel()
            streamTask = nil
            streamingContent = nil
            currentTool = nil
        }

        isProcessing = true
        let content = messageText ?? String(section.content.characters)

        streamTask = Task {
            // 1. Persist user message to DB
            // Evaluate isNew BEFORE inserting — it must reflect whether the session had
            // prior messages, not whether the message we're about to insert exists yet.
            let isNew = seenMessageIds.isEmpty
            do {
                let msg = try MessageStore.shared.sendMessage(
                    sessionId: sessionId, role: .user, content: content)
                // Pre-register the section UUID under this DB message ID so applyMessages
                // returns the same UUID and never creates a duplicate view.
                if let uuid = sectionUUID {
                    stableSectionIds[msg.id] = uuid
                }
                seenMessageIds.insert(msg.id)
            } catch {
                canvasLog("[DocumentEditor] Failed to persist user message: \(error)")
            }

            // 2. Route through ClaudeCodeProvider
            let model = UserDefaults.standard.string(forKey: "defaultModel") ?? CortanaConstants.defaultModel

            // Context injection strategy — two tiers to handle both cold starts and
            // back-to-back --resume failures:
            //
            // • Always:  last 2 turns (immediate reminder, ~150 tokens). Covers the case
            //            where --resume silently fails on a consecutive message — Claude
            //            always has at minimum the previous exchange.
            //
            // • Stale:   last 8 turns injected when first send after launch or >15 min gap.
            //            Covers session expiry after leaving the app.
            let now = Date()
            let isSessionStale = lastSendTimestamp.map {
                now.timeIntervalSince($0) > DocumentEditorViewModel.sessionStaleInterval
            } ?? true  // nil = first send this launch
            lastSendTimestamp = now

            let allSections = document.sections
            let maxAdditional = isSessionStale ? 8 : 2   // 12 total stale, 6 total active
            let contextSections = ConversationScorer.select(
                sections: allSections,
                query: content,
                mandatoryCount: 4,
                maxAdditional: maxAdditional
            )

            let recentContext: String? = {
                guard !contextSections.isEmpty else { return nil }
                let lines = contextSections.map { section -> String in
                    let role: String
                    switch section.author {
                    case .user: role = "You"
                    case .assistant: role = LocalAgentIdentity.name
                    case .system: role = "System"
                    }
                    let text = String(section.content.characters.prefix(500))
                    return "[\(role)]: \(text)"
                }
                if isSessionStale {
                    canvasLog("[DocumentEditor] Stale session — injecting \(contextSections.count) turns")
                }
                return "CONVERSATION CONTEXT (recent history — use if session memory is unclear):\n"
                    + lines.joined(separator: "\n\n")
                    + "\nEND CONTEXT"
            }()

            // Prefer the sidebar-selected project path when available;
            // fall back to the tree's stored project name.
            let resolvedProject = AppState.shared.selectedProjectPath.flatMap {
                URL(fileURLWithPath: $0).lastPathComponent
            } ?? cachedProject

            let ctx = ProviderSendContext(
                message: content,
                sessionId: sessionId,
                branchId: branchId,
                model: model,
                workingDirectory: AppState.shared.selectedProjectPath ?? workingDirectory,
                project: resolvedProject,
                parentSessionId: cachedParentSessionId,
                isNewSession: isNew,
                attachments: attachments,
                recentContext: recentContext
            )

            // 4. Stream response through ClaudeBridge — routes via Friday daemon if available,
            //    falls back to ProviderManager (ClaudeCodeProvider) automatically.
            var fullResponse = ""
            var hadExplicitError = false
            streamingContent = ""  // Start streaming indicator
            startStreamBatching()

            // Open SSD crash-recovery file — fire-and-forget, doesn't need to be ready
            // before the first token. appendToStream() guards on handle presence.
            Task { await StreamCacheManager.shared.openStreamFile(sessionId: sessionId) }

            for await event in claudeBridge.send(context: ctx) {
                // Bail out cleanly if this task was cancelled (user interrupted)
                if Task.isCancelled {
                    canvasLog("[DocumentEditor] Stream task cancelled — stopping token consumption")
                    break
                }

                switch event {
                case .text(let token):
                    fullResponse += token
                    pendingTokenBuffer += token  // batched — Timer flushes at 60fps
                    BranchTerminalManager.shared.send(to: branchId, text: token)
                    // Fire-and-forget — actor serialises writes, never blocks the stream
                    Task { await StreamCacheManager.shared.appendToStream(sessionId: self.sessionId, chunk: token) }

                case .toolStart(let name, let input):
                    let activity = ToolActivity(name: name, input: input, status: .running)
                    currentTool = activity.displayDescription

                case .toolEnd:
                    currentTool = nil

                case .done:
                    break

                case .error(let msg):
                    hadExplicitError = true
                    canvasLog("[DocumentEditor] Provider error: \(msg)")
                    if fullResponse.isEmpty {
                        fullResponse = "⚠️ \(msg)"
                    }
                }
            }
            stopStreamBatching()       // flush remaining tokens, stop timer
            streamingContent = nil     // Stream complete — persisted section takes over
            hasNewStreamContent = false

            // If cancelled, skip persist — the interruption handler already saved the partial
            guard !Task.isCancelled else { return }
            // If stream ended with no output and no explicit error, the CLI silently failed.
            if fullResponse.isEmpty && !hadExplicitError {
                fullResponse = "⚠️ No response received. The request may have been rate-limited or timed out. Please try again."
                canvasLog("[DocumentEditor] Stream ended with no output — surfacing silent failure to user")
            }

            // 5. Persist assistant response, THEN clear streaming so there's never a gap
            // where neither the stream view nor the persisted section is visible.
            if !fullResponse.isEmpty {
                do {
                    let msg = try MessageStore.shared.sendMessage(
                        sessionId: sessionId, role: .assistant, content: fullResponse)
                    seenMessageIds.insert(msg.id)
                    let assistantSection = DocumentSection(
                        id: stableId(for: msg.id),
                        content: AttributedString(fullResponse),
                        author: .assistant,
                        timestamp: msg.createdAt,
                        branchPoint: true,
                        isEditable: false,
                        messageId: msg.id,
                        hasFindingSignal: !isRootBranch && scanForFindingSignals(fullResponse)
                    )
                    document.sections.append(assistantSection)
                } catch {
                    canvasLog("[DocumentEditor] Failed to persist assistant response: \(error)")
                    let assistantSection = DocumentSection(
                        content: AttributedString(fullResponse),
                        author: .assistant,
                        timestamp: Date(),
                        branchPoint: true,
                        isEditable: false
                    )
                    document.sections.append(assistantSection)
                }
            }
            // Clean completion — delete the temp file (nothing to recover)
            // Actor serialises this after any pending appendToStream calls finish
            await StreamCacheManager.shared.closeStream(sessionId: sessionId)

            // Update local context cache so next request builds context from SSD, not Dropbox
            let cacheLimit = await StreamCacheManager.shared.contextMessageLimit
            let cachedMsgs: [StreamCacheManager.CachedMessage] = document.sections.suffix(cacheLimit).map { section in
                let role: String
                switch section.author {
                case .user:      role = "user"
                case .assistant: role = "assistant"
                case .system:    role = "system"
                }
                return StreamCacheManager.CachedMessage(
                    role: role,
                    content: String(section.content.characters),
                    timestamp: section.timestamp
                )
            }
            await StreamCacheManager.shared.updateContextCache(sessionId: sessionId, messages: cachedMsgs)

            streamingContent = nil  // Clear AFTER section is in place — no blank gap
            currentTool = nil

            // Notify if app is backgrounded so the user knows the response arrived
            if !fullResponse.hasPrefix("⚠️"), !NSApp.isActive {
                let preview = String(fullResponse.prefix(120))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await NotificationManager.shared.notify(title: LocalAgentIdentity.name, body: preview) }
            }

            // Auto-speak the response if enabled
            if UserDefaults.standard.bool(forKey: "voiceAutoSpeak"),
               !fullResponse.hasPrefix("⚠️") {
                let speakText = fullResponse.count > 500
                    ? String(fullResponse.prefix(500)) + "..."
                    : fullResponse
                // Strip markdown for cleaner speech
                let cleanText = speakText
                    .replacingOccurrences(of: "```[\\s\\S]*?```", with: " code block ", options: .regularExpression)
                    .replacingOccurrences(of: "`[^`]+`", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "#+ ", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "**", with: "")
                let rawSpeed = UserDefaults.standard.double(forKey: "voiceSpeed")
                let rawPitch = UserDefaults.standard.double(forKey: "voicePitch")
                let voiceOptions = SpeechOptions(
                    speed: rawSpeed > 0 ? min(max(rawSpeed, 0.5), 2.0) : 1.0,
                    pitch: rawPitch > 0 ? min(max(rawPitch, 0.5), 2.0) : 1.0
                )
                Task { try? await VoiceService.shared.speak(cleanText, options: voiceOptions) }
            }

            isProcessing = false
            streamTask = nil
        }
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
        canvasLog("[DocumentEditor] Accepting branch suggestion: \(suggestion.title)")

        // Clear the opportunity
        branchOpportunity = nil

        // Notify parent to create branch
        parentBranchLayout?.createBranchFromSuggestion(suggestion, userInput: currentInput)

        // Clear input
        currentInput = ""
    }

    func spawnParallelBranches() {
        guard let opportunity = branchOpportunity else { return }

        canvasLog("[DocumentEditor] Spawning \(opportunity.suggestions.count) parallel branches")

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
            Text("💠")
                .font(.system(size: 48))

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

    @State private var phase = 0
    @State private var dotTimer: Timer?

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
                // Three-circle dot animation — no text overflow
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Color.teal)
                            .frame(width: 7, height: 7)
                            .opacity(phase == i ? 1.0 : 0.3)
                            .scaleEffect(phase == i ? 1.2 : 0.8)
                            .animation(.easeInOut(duration: 0.25), value: phase)
                    }
                }
                .padding(.top, 12)

                if let description = toolDescription {
                    Text(description)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.teal.opacity(0.5))
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            dotTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                phase = (phase + 1) % 3
            }
        }
        .onDisappear {
            dotTimer?.invalidate()
            dotTimer = nil
        }
    }
}

// MARK: - Live Streaming Section

struct StreamingSectionView: View {
    let content: String

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
    }

    @ViewBuilder
    private var markdownContent: some View {
        if content.isEmpty {
            Text(" ")
        } else {
            // Use the same structured renderer as completed sections so streaming
            // output has paragraph breaks, headers, and code blocks — not a wall of text.
            let rendered = (try? AttributedString(
                markdown: content,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full
                )
            )) ?? AttributedString(content)
            MarkdownCodeFenceView(raw: content, rendered: rendered)
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
    var onTabKey: (() -> Bool)?
    var onShiftTabKey: (() -> Bool)?
    var onCmdReturnKey: (() -> Bool)?

    @FocusState private var editorFocused: Bool
    @State private var isDragTargeted = false
    @State private var isListening = false
    @State private var liveTranscription = ""

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
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        } else if text.isEmpty {
                            Text("Add a message…")
                                .font(.system(.body))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }

                        KeyboardHandlingTextEditor(
                            text: $text,
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
                    .frame(minHeight: 60)
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

                        Button(action: onSubmit) {
                            Label(
                                isProcessing ? "Sending…" : "Send",
                                systemImage: isProcessing ? "arrow.trianglehead.clockwise" : "paperplane.fill"
                            )
                            .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                            || isProcessing
                        )
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
                    canvasLog("[VoiceInput] Failed to start: \(error)")
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
