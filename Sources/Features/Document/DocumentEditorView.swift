import SwiftUI

/// Google Docs-style collaborative document editor for conversations
struct DocumentEditorView: View {
    @StateObject private var viewModel: DocumentEditorViewModel
    @FocusState private var isFocused: Bool
    @State private var hoveredSectionId: UUID?

    init(sessionId: String) {
        _viewModel = StateObject(wrappedValue: DocumentEditorViewModel(sessionId: sessionId))
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

                        UserInputArea(
                            text: $viewModel.currentInput,
                            isProcessing: viewModel.isProcessing,
                            onSubmit: { viewModel.submitInput() }
                        )
                        .focused($isFocused)
                        .padding(.bottom, 24)
                    }
                    .padding(.horizontal, max(24, (geometry.size.width - 800) / 2))
                    .padding(.vertical, 24)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onAppear {
                    isFocused = true
                    viewModel.loadDocument()
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
    @Published var currentInput = ""
    @Published var isProcessing = false

    private let sessionId: String

    init(sessionId: String) {
        self.sessionId = sessionId
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
        // TODO: Load messages from database and convert to document sections
        // For now, create sample document
        let sampleSections = [
            DocumentSection(
                content: AttributedString("Welcome to Cortana Canvas"),
                author: .system,
                timestamp: Date(),
                branchPoint: false,
                isEditable: false
            ),
            DocumentSection(
                content: AttributedString("This is a living document interface. You can edit anywhere, branch conversations, and collaborate seamlessly."),
                author: .assistant,
                timestamp: Date(),
                branchPoint: true,
                isEditable: false
            )
        ]

        document.sections = sampleSections
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
        guard !currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Add user input as new section
        let userSection = DocumentSection(
            content: AttributedString(currentInput),
            author: .user(name: "Evan"),
            timestamp: Date(),
            branchPoint: true,
            isEditable: true
        )

        document.sections.append(userSection)
        currentInput = ""

        // TODO: Send to Claude for response
        processUserInput(userSection)
    }

    private func processUserInput(_ section: DocumentSection) {
        isProcessing = true

        Task {
            do {
                // Send to Claude via gateway
                let client = GatewayClient(authToken: "dev-token")

                // Build conversation context from all sections
                let messages = document.sections.map { section -> String in
                    let role = switch section.author {
                    case .user: "user"
                    case .assistant: "assistant"
                    case .system: "system"
                    }
                    return "\(role): \(section.content)"
                }.joined(separator: "\n\n")

                // For now, just acknowledge - real gateway streaming coming next
                let response = "I received your message! (Full Claude integration via gateway streaming coming next)"

                await MainActor.run {
                    let assistantSection = DocumentSection(
                        content: AttributedString(response),
                        author: .assistant,
                        timestamp: Date(),
                        branchPoint: true,
                        isEditable: false
                    )
                    self.document.sections.append(assistantSection)
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    print("Error calling Claude: \(error)")
                    self.isProcessing = false
                }
            }
        }
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
                    TextEditor(text: $text)
                        .font(.system(.body))
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                        )
                        .onSubmit {
                            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                onSubmit()
                            }
                        }

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
