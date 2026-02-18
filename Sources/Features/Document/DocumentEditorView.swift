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
                .onChange(of: viewModel.document.sections.count) { _ in
                    if let lastSection = viewModel.document.sections.last {
                        proxy.scrollTo(lastSection.id, anchor: .bottom)
                    }
                }
                // Auto-scroll during streaming — keeps the cursor visible
                .onChange(of: viewModel.streamingContent) { _ in
                    if viewModel.streamingContent != nil {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
                // Auto-scroll to thinking indicator when processing starts
                .onChange(of: viewModel.isProcessing) { _ in
                    if viewModel.isProcessing {
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
            // Analyze input for branch opportunities as user types
            Task {
                await analyzeForBranchOpportunities()
            }
        }
    }
    @Published var isProcessing = false
    @Published var branchOpportunity: BranchOpportunity?
    /// Live token stream content — shown in the chat as Cortana types.
    /// Nil when not streaming; cleared once the full response is persisted.
    @Published var streamingContent: String?

    private let sessionId: String
    private let branchId: String
    private let workingDirectory: String
    private var seenMessageIds: Set<String> = []
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
    }

    /// Returns a stable UUID for a given message ID string.
    /// Message IDs are integers, not UUIDs — without this, SwiftUI sees a new
    /// identity on every render cycle and thrashes the view hierarchy.
    private func stableId(for messageId: String) -> UUID {
        if let existing = stableSectionIds[messageId] { return existing }
        let id = UUID(uuidString: messageId) ?? UUID()
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

    func submitInput() {
        guard !currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let inputText = currentInput
        currentInput = ""

        // Create section for immediate UI feedback
        let userSection = DocumentSection(
            content: AttributedString(inputText),
            author: .user(name: "You"),
            timestamp: Date(),
            branchPoint: true,
            isEditable: true
        )

        // Add to UI immediately (database write happens in processUserInput)
        document.sections.append(userSection)

        // Send to daemon
        processUserInput(userSection)
    }

    private func processUserInput(_ section: DocumentSection) {
        isProcessing = true
        let content = String(section.content.characters)

        Task {
            // 1. Persist user message to DB
            if let msg = try? MessageStore.shared.sendMessage(
                sessionId: sessionId, role: .user, content: content) {
                seenMessageIds.insert(msg.id)
            }

            // 2. Echo to the branch's terminal (user sees their own message as context)
            BranchTerminalManager.shared.send(to: branchId, text: "\n\u{001B}[90m# \(content)\u{001B}[0m\n")

            // 3. Route through ClaudeCodeProvider
            // isNewSession is true only if no messages have been persisted yet
            let isNew = seenMessageIds.isEmpty
            let model = UserDefaults.standard.string(forKey: "defaultModel") ?? CortanaConstants.defaultModel
            let ctx = ProviderSendContext(
                message: content,
                sessionId: sessionId,
                branchId: branchId,
                model: model,
                workingDirectory: workingDirectory,
                project: nil,
                parentSessionId: nil,
                isNewSession: isNew
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
            if !fullResponse.isEmpty,
               let msg = try? MessageStore.shared.sendMessage(
                   sessionId: sessionId, role: .assistant, content: fullResponse) {
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
    let isProcessing: Bool
    let onSubmit: () -> Void
    var onTabKey: (() -> Bool)?
    var onShiftTabKey: (() -> Bool)?
    var onCmdReturnKey: (() -> Bool)?

    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                // Cortana / user avatar — neutral diamond, avoids hardcoded initials
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                // Input field
                VStack(alignment: .leading, spacing: 4) {
                    ZStack(alignment: .topLeading) {
                        // Placeholder — visible only when text is empty
                        if text.isEmpty {
                            Text("Message Cortana…")
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
                                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    onSubmit()
                                }
                            }
                        )
                        .focused($editorFocused)
                    }
                    .frame(minHeight: 60)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                editorFocused ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor),
                                lineWidth: editorFocused ? 2 : 1
                            )
                    )

                    HStack {
                        Spacer()
                        Button(action: onSubmit) {
                            Label(
                                isProcessing ? "Sending…" : "Send",
                                systemImage: isProcessing ? "arrow.trianglehead.clockwise" : "paperplane.fill"
                            )
                            .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
                    }
                }
            }
        }
    }
}
