import SwiftUI
import Foundation
import GRDB

/// Google Docs-style collaborative document editor for conversations
struct DocumentEditorView: View {
    @StateObject private var viewModel: DocumentEditorViewModel
    @FocusState private var isFocused: Bool
    @State private var hoveredSectionId: UUID?
    @State private var selectedSuggestionIndex = 0

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
                                onEdit: { newContent in
                                    viewModel.updateSection(section.id, content: newContent)
                                },
                                onBranch: {
                                    viewModel.createBranch(from: section.id)
                                },
                                onFixError: { failedCall in
                                    viewModel.fixWithClaude(failedCall)
                                }
                            )
                            .id(section.id)
                            .onHover { hovering in
                                hoveredSectionId = hovering ? section.id : nil
                            }
                        }

                        // Live streaming section — tokens appear as they arrive
                        if let streaming = viewModel.streamingContent {
                            StreamingSectionView(content: streaming)
                                .id("streaming")
                        }

                        // Thinking indicator — shows between submit and first token
                        if viewModel.isProcessing && viewModel.streamingContent == nil {
                            ThinkingIndicatorView()
                                .id("thinking")
                                .padding(.horizontal, 0)
                                .padding(.vertical, 8)
                        }

                        // User input area (always at bottom)
                        Divider()
                            .padding(.vertical, 16)

                        VStack(alignment: .leading, spacing: 16) {
                            // Ghost suggestions (if any)
                            if let opportunity = viewModel.branchOpportunity {
                                GhostSuggestionView(
                                    suggestions: opportunity.suggestions,
                                    selectedIndex: selectedSuggestionIndex,
                                    onAccept: { suggestion in
                                        viewModel.acceptSuggestion(suggestion)
                                    },
                                    onAcceptAll: {
                                        viewModel.spawnParallelBranches()
                                    }
                                )
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                            }

                            UserInputArea(
                                text: $viewModel.currentInput,
                                attachments: $viewModel.pendingAttachments,
                                isProcessing: viewModel.isProcessing,
                                onSubmit: { viewModel.submitInput() },
                                onTabKey: {
                                    if viewModel.branchOpportunity != nil {
                                        // Tab cycles through suggestions
                                        selectedSuggestionIndex = (selectedSuggestionIndex + 1) % (viewModel.branchOpportunity?.suggestions.count ?? 1)
                                        return true // handled
                                    }
                                    return false
                                },
                                onShiftTabKey: {
                                    if let opportunity = viewModel.branchOpportunity {
                                        // Accept selected suggestion
                                        viewModel.acceptSuggestion(opportunity.suggestions[selectedSuggestionIndex])
                                        selectedSuggestionIndex = 0
                                        return true
                                    }
                                    return false
                                },
                                onCmdReturnKey: {
                                    if viewModel.branchOpportunity != nil {
                                        // Spawn all branches in parallel
                                        viewModel.spawnParallelBranches()
                                        return true
                                    }
                                    return false
                                }
                            )
                            .focused($isFocused)
                        }
                        .padding(.bottom, 24)
                    }
                    .padding(.horizontal, max(24, (geometry.size.width - 800) / 2))
                    .padding(.vertical, 24)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onAppear {
                    isFocused = true
                    viewModel.loadDocument()
                    viewModel.parentBranchLayout = parentBranchLayout
                }
                // Unified scroll handler — one source of truth, no race conditions.
                // Priority: streaming > thinking > new section (never fight each other).
                .onChange(of: viewModel.document.sections.count) { _ in
                    // Only scroll to new section when not streaming — streaming handler owns the anchor then.
                    guard viewModel.streamingContent == nil, !viewModel.isProcessing else { return }
                    if let lastSection = viewModel.document.sections.last {
                        proxy.scrollTo(lastSection.id, anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.streamingContent) { content in
                    if content != nil {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    } else if let lastSection = viewModel.document.sections.last {
                        // Streaming ended — snap to the persisted section that replaced it
                        proxy.scrollTo(lastSection.id, anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.isProcessing) { processing in
                    if processing && viewModel.streamingContent == nil {
                        proxy.scrollTo("thinking", anchor: .bottom)
                    }
                }
            }
        }
    }
}

@MainActor
class DocumentEditorViewModel: ObservableObject {
    @Published var document: ConversationDocument
    @Published var currentInput = "" {
        didSet {
            Task { await analyzeForBranchOpportunities() }
        }
    }
    @Published var pendingAttachments: [Attachment] = []
    @Published var isProcessing = false
    @Published var branchOpportunity: BranchOpportunity?
    /// Live token stream content — shown in the chat as Cortana types.
    /// Nil when not streaming; cleared once the full response is persisted.
    @Published var streamingContent: String?

    private let sessionId: String
    private let branchId: String
    private let workingDirectory: String
    private var cachedProject: String?
    private var seenMessageIds: Set<String> = []

    /// Timestamp of the last successful send — used to detect stale CLI sessions.
    /// nil = no send yet this launch (treat as stale).
    private var lastSendTimestamp: Date?
    private static let sessionStaleInterval: TimeInterval = 15 * 60  // 15 min
    /// Stable UUID per message ID — prevents random UUIDs being generated each
    /// render cycle when msg.id is an integer string (not a UUID string).
    private var stableSectionIds: [String: UUID] = [:]
    /// GRDB ValueObservation cancellable — auto-cancels when view model is deallocated.
    private var messageObservation: AnyDatabaseCancellable?
    weak var parentBranchLayout: BranchLayoutViewModel?

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
        guard messageObservation == nil,
              let dbPool = DatabaseManager.shared.dbPool else { return }

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

        // Pre-warm provider context so the first message has zero cold-start delay.
        // Runs in background — doesn't block the UI.
        Task { [weak self] in
            guard let self else { return }
            let project = (try? TreeStore.shared.getBranchBySessionId(self.sessionId))
                .flatMap { branch -> String? in
                    (try? TreeStore.shared.getTree(branch.treeId))?.project
                }
            self.cachedProject = project
            let provider = ProviderManager.shared.providers.first { $0.identifier == "claude-code" }
                ?? ProviderManager.shared.activeProvider
            await provider?.warmUp(
                sessionId: self.sessionId,
                branchId: self.branchId,
                project: project,
                workingDirectory: self.workingDirectory
            )
        }
    }

    /// Returns a stable UUID for a given message ID string.
    /// Message IDs from the DB are integers ("42", "123") — not valid UUID strings.
    /// We derive a deterministic UUID by hashing the ID so the same message
    /// always maps to the same UUID across render cycles, preventing view thrash.
    private func stableId(for messageId: String) -> UUID {
        if let existing = stableSectionIds[messageId] { return existing }
        // Deterministic: pad the integer string into a UUID namespace
        // Format: 00000000-0000-0000-0000-XXXXXXXXXXXX where X is the message ID
        let padded = messageId.padding(toLength: 12, withPad: "0", startingAt: 0)
        let uuidString = "00000000-0000-0000-0000-\(padded.suffix(12))"
        let id = UUID(uuidString: uuidString) ?? UUID()
        stableSectionIds[messageId] = id
        return id
    }

    /// Applies the latest full message list from ValueObservation.
    /// Only appends new messages — preserves existing section order and identity.
    private func applyMessages(_ messages: [Message]) {
        let newMessages = messages.filter { !seenMessageIds.contains($0.id) }

        for msg in newMessages {
            let author: Author = {
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
                isEditable: msg.role == .user
            )
            document.sections.append(section)
            seenMessageIds.insert(msg.id)
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

    func createBranch(from sectionId: UUID) {
        guard let index = document.sections.firstIndex(where: { $0.id == sectionId }) else {
            return
        }

        // TODO: Implement branch creation
        // 1. Take all sections up to this point
        // 2. Create new branch in database
        // 3. Navigate to new branch
        print("Creating branch from section at index \(index)")
    }

    /// One-click error recovery: inject structured error context + auto-submit.
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
        isProcessing = true
        let content = messageText ?? String(section.content.characters)

        Task {
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

            // 2. Echo to the branch's terminal (user sees their own message as context)
            BranchTerminalManager.shared.send(to: branchId, text: "\n\u{001B}[90m# \(content)\u{001B}[0m\n")

            // 3. Route through ClaudeCodeProvider
            let model = UserDefaults.standard.string(forKey: "defaultModel") ?? CortanaConstants.defaultModel

            // Smart context injection: only inject conversation history when the CLI
            // session might be stale (first send after launch, or >15 min gap).
            // Active conversations trust --resume and skip the overhead.
            let now = Date()
            let isSessionStale = lastSendTimestamp.map {
                now.timeIntervalSince($0) > DocumentEditorViewModel.sessionStaleInterval
            } ?? true  // nil = first send this launch = always inject
            lastSendTimestamp = now

            let recentContext: String? = isSessionStale ? {
                let contextSections = document.sections.suffix(16)  // last ~8 turns
                guard !contextSections.isEmpty else { return nil }
                let lines = contextSections.map { section -> String in
                    let role: String
                    switch section.author {
                    case .user: role = "You"
                    case .assistant: role = "Cortana"
                    case .system: role = "System"
                    }
                    let text = String(section.content.characters.prefix(500))
                    return "[\(role)]: \(text)"
                }
                canvasLog("[DocumentEditor] Injecting \(contextSections.count) turns as stale-session fallback")
                return "CONVERSATION CONTEXT (recent history — use if session memory is unclear):\n"
                    + lines.joined(separator: "\n\n")
                    + "\nEND CONTEXT"
            }() : nil

            let ctx = ProviderSendContext(
                message: content,
                sessionId: sessionId,
                branchId: branchId,
                model: model,
                workingDirectory: workingDirectory,
                project: cachedProject,
                parentSessionId: nil,
                isNewSession: isNew,
                attachments: attachments,
                recentContext: recentContext
            )

            let provider = ProviderManager.shared.providers.first { $0.identifier == "claude-code" }
                        ?? ProviderManager.shared.activeProvider

            guard let provider else {
                isProcessing = false
                BranchTerminalManager.shared.send(to: branchId, text: "\n\u{001B}[31m[error: no provider]\u{001B}[0m\n")
                return
            }

            // 4. Stream response — mirror every token to the chat and terminal in real time
            var fullResponse = ""
            streamingContent = ""  // Start streaming indicator

            for await event in provider.send(context: ctx) {
                switch event {
                case .text(let token):
                    fullResponse += token
                    streamingContent = fullResponse  // Live update in chat
                    BranchTerminalManager.shared.send(to: branchId, text: token)

                case .toolStart(let name, _):
                    BranchTerminalManager.shared.send(to: branchId, text: "\n\u{001B}[36m[→ \(name)]\u{001B}[0m\n")

                case .toolEnd(let name, _, let isError):
                    let icon = isError ? "✗" : "✓"
                    let color = isError ? "\u{001B}[31m" : "\u{001B}[32m"
                    BranchTerminalManager.shared.send(to: branchId, text: "\(color)[\(icon) \(name)]\u{001B}[0m\n")

                case .done:
                    break

                case .error(let msg):
                    BranchTerminalManager.shared.send(to: branchId, text: "\n\u{001B}[31m[error: \(msg)]\u{001B}[0m\n")
                }
            }
            streamingContent = nil  // Stream complete — persisted section takes over

            // 5. Persist assistant response — polling observer will surface it in the chat
            if !fullResponse.isEmpty {
                do {
                    let msg = try MessageStore.shared.sendMessage(
                        sessionId: sessionId, role: .assistant, content: fullResponse)
                    seenMessageIds.insert(msg.id)
                    // Add directly to avoid polling delay
                    let assistantSection = DocumentSection(
                        id: stableId(for: msg.id),
                        content: AttributedString(fullResponse),
                        author: .assistant,
                        timestamp: msg.createdAt,
                        branchPoint: true,
                        isEditable: false
                    )
                    document.sections.append(assistantSection)
                } catch {
                    canvasLog("[DocumentEditor] Failed to persist assistant response: \(error)")
                    // Still display the response — content is not lost from UI even if DB write failed
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

            isProcessing = false
            BranchTerminalManager.shared.send(to: branchId, text: "\n")
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
        // Create a new branch with this suggestion
        print("Accepting suggestion: \(suggestion.title)")

        // Clear the opportunity
        branchOpportunity = nil

        // Notify parent to create branch
        parentBranchLayout?.createBranchFromSuggestion(suggestion, userInput: currentInput)

        // Clear input
        currentInput = ""
    }

    func spawnParallelBranches() {
        guard let opportunity = branchOpportunity else { return }

        print("Spawning \(opportunity.suggestions.count) parallel branches")

        // Clear the opportunity
        branchOpportunity = nil

        // Notify parent to create multiple branches
        parentBranchLayout?.spawnParallelBranches(opportunity.suggestions, userInput: currentInput)

        // Clear input
        currentInput = ""
    }

    func showBranchView() {
        // TODO: Show branch navigation UI
    }

    func showContextControl() {
        // TODO: Show context management UI
    }

    func exportMarkdown() {
        // TODO: Export document as Markdown
    }

    func exportPDF() {
        // TODO: Export document as PDF
    }

    func share() {
        // TODO: Share document
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

            Text("Ask anything — Cortana has full access to your project files,\nterminal, and knowledge base.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .padding()
    }
}

// MARK: - Thinking Indicator (3-dot animation)

struct ThinkingIndicatorView: View {
    @State private var phase = 0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Cortana avatar
            Circle()
                .fill(Color.cyan.gradient)
                .frame(width: 32, height: 32)
                .overlay {
                    Text("💠")
                        .font(.system(size: 14))
                }

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.secondary.opacity(phase == i ? 1.0 : 0.3))
                        .frame(width: 7, height: 7)
                        .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.2), value: phase)
                }
            }
            .padding(.vertical, 12)
        }
        .onAppear {
            withAnimation {
                phase = (phase + 1) % 3
            }
            // Cycle the dot
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                withAnimation {
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}

// MARK: - Live Streaming Section

struct StreamingSectionView: View {
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.cyan.gradient)
                .frame(width: 32, height: 32)
                .overlay {
                    Text("💠")
                        .font(.system(size: 14))
                }

            VStack(alignment: .leading, spacing: 8) {
                Text(content.isEmpty ? " " : content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Blinking cursor
                HStack(spacing: 0) {
                    BlinkingCursor()
                }
            }
            .padding(.vertical, 8)

            Spacer()
        }
        .padding(.horizontal, 0)
    }
}

struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(Color.cyan)
            .frame(width: 2, height: 14)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                    visible.toggle()
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
                            Text("Message Cortana… or drop images/files here")
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
