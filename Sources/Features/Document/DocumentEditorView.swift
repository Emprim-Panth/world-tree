import SwiftUI
import Foundation

// MARK: - Debug Logging Helper

extension String {
    func appendToFile(_ path: String) throws {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            if let data = self.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            try self.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }
}

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
        print("🏗️ [DocumentEditorView] Initializing with sessionId: \(sessionId)")
        self.parentBranchLayout = parentBranchLayout
        _viewModel = StateObject(wrappedValue: DocumentEditorViewModel(
            sessionId: sessionId,
            branchId: branchId,
            workingDirectory: workingDirectory
        ))
        print("✅ [DocumentEditorView] Initialized")
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
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

    private let sessionId: String
    private let branchId: String
    private let workingDirectory: String
    private var seenMessageIds: Set<String> = []
    weak var parentBranchLayout: BranchLayoutViewModel?

    init(sessionId: String, branchId: String, workingDirectory: String) {
        print("🎬 [DocumentEditorViewModel] Initializing with sessionId: \(sessionId)")
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
        print("✅ [DocumentEditorViewModel] Initialized")
    }

    func loadDocument() {
        // Load existing messages from database
        Task {
            do {
                let messages = try MessageStore.shared.getMessages(sessionId: sessionId)

                await MainActor.run {
                    document.sections = messages.map { msg in
                        let author: Author = {
                            switch msg.role {
                            case .user: return .user(name: "You")
                            case .assistant: return .assistant
                            case .system: return .system
                            }
                        }()

                        return DocumentSection(
                            id: UUID(uuidString: msg.id) ?? UUID(),
                            content: AttributedString(msg.content),
                            author: author,
                            timestamp: msg.createdAt,
                            branchPoint: true,
                            isEditable: msg.role == .user
                        )
                    }

                    // Track which message IDs we've already shown
                    self.seenMessageIds = Set(messages.map { $0.id })

                    // Start watching for new messages
                    startMessageObserver()
                }
            } catch {
                print("Error loading messages: \(error)")
            }
        }
    }

    private func startMessageObserver() {
        // Poll for new messages every second
        // TODO: Use DatabaseRegionObservation for real-time updates
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.checkForNewMessages()
            }
        }
    }

    private func checkForNewMessages() async {
        do {
            let messages = try MessageStore.shared.getMessages(sessionId: sessionId)

            await MainActor.run {
                // Filter using string IDs — message IDs are integers, not UUIDs
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
                        id: UUID(uuidString: msg.id) ?? UUID(),
                        content: AttributedString(msg.content),
                        author: author,
                        timestamp: msg.createdAt,
                        branchPoint: true,
                        isEditable: msg.role == .user
                    )
                    document.sections.append(section)
                    seenMessageIds.insert(msg.id)
                }

                // Stop processing indicator when assistant responds
                if newMessages.contains(where: { $0.role == .assistant }) {
                    isProcessing = false
                }
            }
        } catch {
            print("Error checking for new messages: \(error)")
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
        let logMsg = "📤 [DocumentEditor] submitInput() called\n"
        try? logMsg.write(toFile: "/tmp/canvas-debug.log", atomically: false, encoding: .utf8)

        guard !currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try? "⚠️ [DocumentEditor] Input is empty\n".appendToFile("/tmp/canvas-debug.log")
            return
        }

        let inputText = currentInput
        try? "📤 [DocumentEditor] Input text: '\(inputText)'\n".appendToFile("/tmp/canvas-debug.log")
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
        print("✅ [DocumentEditor] Added section to document, total sections: \(document.sections.count)")

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
            let isNew = document.sections.count <= 1
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

            // 4. Stream response — mirror every token and tool event to the terminal in real time
            var fullResponse = ""

            for await event in provider.send(context: ctx) {
                switch event {
                case .text(let token):
                    fullResponse += token
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

            // 5. Persist assistant response — polling observer will surface it in the chat
            if !fullResponse.isEmpty,
               let msg = try? MessageStore.shared.sendMessage(
                   sessionId: sessionId, role: .assistant, content: fullResponse) {
                seenMessageIds.insert(msg.id)
                // Add directly to avoid polling delay
                let assistantSection = DocumentSection(
                    id: UUID(uuidString: msg.id) ?? UUID(),
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

// MARK: - User Input Area

struct UserInputArea: View {
    @Binding var text: String
    let isProcessing: Bool
    let onSubmit: () -> Void
    var onTabKey: (() -> Bool)?  // Return true if handled
    var onShiftTabKey: (() -> Bool)?
    var onCmdReturnKey: (() -> Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                // User indicator
                Circle()
                    .fill(Color.blue.gradient)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Text("E")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }

                // Input field
                VStack(alignment: .leading, spacing: 4) {
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
                    .frame(minHeight: 60)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )

                    HStack {
                        if isProcessing {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Processing...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(action: onSubmit) {
                            Label("Send", systemImage: "paperplane.fill")
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
