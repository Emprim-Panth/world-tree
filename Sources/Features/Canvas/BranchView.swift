import SwiftUI

// Preference key for tracking scroll position
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct BranchView: View {
    let branchId: String

    @StateObject private var viewModel: BranchViewModel
    @EnvironmentObject var appState: AppState
    @State private var showForkSheet = false
    @State private var forkSourceMessage: Message?
    @State private var forkType: BranchType = .conversation

    init(branchId: String) {
        self.branchId = branchId
        _viewModel = StateObject(wrappedValue: BranchViewModel(branchId: branchId))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            if let branch = viewModel.branch {
                BranchHeaderView(
                    branch: branch,
                    branchPath: viewModel.branchPath,
                    siblings: viewModel.siblings,
                    activityCount: viewModel.activityCount,
                    contextUsage: viewModel.contextUsage,
                    isResponding: viewModel.isResponding,
                    onNavigateToBranch: { branchId in
                        appState.selectBranch(branchId, in: branch.treeId)
                    },
                    onComplete: {
                        completeBranch()
                    }
                )
                Divider()
            }

            // Error banner
            if let error = viewModel.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        viewModel.error = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(.red.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            // Terminal-style conversation view with integrated input
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    ScrollView {
                        GeometryReader { scrollGeometry in
                            Color.clear.preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: scrollGeometry.frame(in: .named("scroll")).minY
                            )
                        }
                        .frame(height: 0)
                        
                        LazyVStack(spacing: 0) {
                        // Summary card if branch has completed children
                        completedChildSummaries

                        ForEach(viewModel.messages) { message in
                            MessageRow(
                                message: message,
                                onFork: { msg, type in
                                    forkSourceMessage = msg
                                    forkType = type
                                    showForkSheet = true
                                },
                                onEdit: { msg, newContent in
                                    if let newBranchId = viewModel.editMessage(msg, newContent: newContent),
                                       let treeId = viewModel.branch?.treeId {
                                        appState.selectBranch(newBranchId, in: treeId)
                                    }
                                }
                            )
                            .id(message.id)
                        }

                        // Streaming response
                        if viewModel.isResponding && !viewModel.streamingResponse.isEmpty {
                            streamingResponseView
                                .id("streaming")
                        }

                        // Live typing preview (only if not responding and user is typing)
                        if !viewModel.isResponding && !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            liveTypingPreview
                                .id("typing-preview")
                        }

                        // Integrated input (terminal-style) - always visible at bottom of scroll
                        if viewModel.branch?.status == .active {
                            integratedInput
                                .id("input")
                        } else if let branch = viewModel.branch {
                            HStack {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                                Text("Branch \(branch.status.rawValue)")
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                        }

                        // Token usage footer (moved inside scroll view)
                        if let usage = viewModel.tokenUsage, usage.turnCount > 0 {
                            tokenUsageFooter(usage)
                                .padding(.top, 8)
                        }

                        // Tool execution timeline
                        if !viewModel.toolTimelineEvents.isEmpty {
                            ToolTimeline(events: viewModel.toolTimelineEvents)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                        }

                        // Bottom padding so input isn't cramped
                        Color.clear.frame(height: 20)
                        }
                        .padding(.vertical, 12)
                    }
                    .coordinateSpace(name: "scroll")
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                        // Detect if user has scrolled up from bottom
                        // If offset is significantly negative, user is not at bottom
                        if offset < -50 {
                            viewModel.shouldAutoScroll = false
                        } else if offset > -10 {
                            // User scrolled back to bottom
                            viewModel.shouldAutoScroll = true
                        }
                    }
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if viewModel.shouldAutoScroll {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.streamingResponse) { _, _ in
                    if viewModel.shouldAutoScroll {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onAppear {
                    // Scroll to bottom on appear
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollToBottom(proxy: proxy)
                    }
                }
            }
        }
        .onAppear {
            viewModel.load()
            viewModel.startObserving()
        }
        .onDisappear {
            viewModel.stopObserving()
        }
        .onChange(of: branchId) { _, newId in
            viewModel.stopObserving()
            // Recreate the view for the new branch ID
        }
        .sheet(isPresented: $showForkSheet) {
            if let message = forkSourceMessage {
                ForkMenu(
                    sourceMessage: message,
                    branchType: $forkType,
                    branch: viewModel.branch
                ) { newBranchId in
                    showForkSheet = false
                    if let treeId = viewModel.branch?.treeId {
                        appState.selectBranch(newBranchId, in: treeId)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNewBranch)) { _ in
            if let lastMsg = viewModel.messages.last {
                forkSourceMessage = lastMsg
                forkType = .conversation
                showForkSheet = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    copyConversation()
                } label: {
                    Label("Copy Conversation", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy entire conversation to clipboard")
            }
        }
    }

    // MARK: - Streaming Response

    private var streamingResponseView: some View {
        HStack(alignment: .top, spacing: 0) {
            // Role gutter
            HStack(spacing: 2) {
                Image(systemName: "diamond.fill")
                    .font(.caption2)
                    .foregroundStyle(.cyan)
                Text("C")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.cyan)
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 2)
            }
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.top, 2)

            // Accent bar (pulsing)
            RoundedRectangle(cornerRadius: 1)
                .fill(.cyan.opacity(0.6))
                .frame(width: 2)

            // Content area
            VStack(alignment: .leading, spacing: 4) {
                // Tool activity indicators
                if !viewModel.toolActivities.isEmpty {
                    ForEach(viewModel.toolActivities) { activity in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                switch activity.status {
                                case .running:
                                    ProgressView()
                                        .controlSize(.mini)
                                case .completed:
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption2)
                                case .failed:
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                        .font(.caption2)
                                }
                                Text(activity.displayDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            // Inline diff for edit_file operations
                            if activity.hasDiffData, let diff = activity.diffData {
                                DiffView(
                                    oldText: diff.oldText,
                                    newText: diff.newText,
                                    filePath: diff.filePath
                                )
                                .frame(maxWidth: 600)
                            }
                        }
                    }
                }

                // Streaming text with markdown rendering
                if !viewModel.streamingResponse.isEmpty {
                    StreamingMarkdownView(text: viewModel.streamingResponse)
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }

    // MARK: - Live Typing Preview

    private var liveTypingPreview: some View {
        HStack(alignment: .top, spacing: 0) {
            // Role gutter
            HStack(spacing: 2) {
                Image(systemName: "person.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                Text("U")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.blue)
            }
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.top, 2)

            // Accent bar
            RoundedRectangle(cornerRadius: 1)
                .fill(.blue.opacity(0.3))
                .frame(width: 2)

            // Preview text
            Text(viewModel.inputText.isEmpty ? " " : viewModel.inputText)
                .font(.body)
                .foregroundStyle(.secondary.opacity(0.7))
                .padding(.leading, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 20)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .opacity(0.6)
    }

    // MARK: - Integrated Input (Terminal Style)

    private var integratedInput: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // Role gutter (consistent with messages)
            HStack(spacing: 2) {
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 8)

            // Accent bar
            RoundedRectangle(cornerRadius: 1)
                .fill(.secondary.opacity(0.2))
                .frame(width: 2)

            // Input field
            HStack(alignment: .bottom, spacing: 8) {
                if viewModel.isResponding {
                    // Show cancel button while Cortana is responding
                    Button {
                        viewModel.cancelResponse()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.circle.fill")
                                .foregroundStyle(.red)
                            Text("Stop")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Cortana is thinking...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Message Cortana...", text: $viewModel.inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...8)
                        .onSubmit {
                            viewModel.sendMessage()
                        }

                    Button {
                        viewModel.sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.background.opacity(0.5))
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if viewModel.isResponding {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if !viewModel.inputText.isEmpty {
                proxy.scrollTo("typing-preview", anchor: .bottom)
            } else {
                proxy.scrollTo("input", anchor: .bottom)
            }
        }
    }

    // MARK: - Completed Child Summaries

    @ViewBuilder
    private var completedChildSummaries: some View {
        if let branch = viewModel.branch, !branch.children.isEmpty {
            let completed = branch.children.filter { $0.status == .completed && $0.summary != nil }
            ForEach(completed) { child in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: child.branchType == .implementation ? "gearshape.fill" : "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(child.displayTitle)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        StatusBadge(status: .completed)
                    }
                    Text(child.summary ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.green.opacity(0.05))
                .cornerRadius(8)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .onTapGesture {
                    appState.selectBranch(child.id, in: branch.treeId)
                }
            }
        }
    }

    // MARK: - Token Usage Footer

    private func tokenUsageFooter(_ usage: SessionTokenUsage) -> some View {
        let totalTokens = usage.totalInputTokens + usage.totalOutputTokens
        let cachePercent = totalTokens > 0
            ? Int(Double(usage.cacheHitTokens) / Double(totalTokens) * 100)
            : 0
        let tokenStr = totalTokens > 1000
            ? String(format: "%.1fK", Double(totalTokens) / 1000)
            : "\(totalTokens)"

        return HStack(spacing: 12) {
            Text("Turn \(usage.turnCount)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("\(tokenStr) tokens")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if cachePercent > 0 {
                Text("\(cachePercent)% cached")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - Copy Conversation

    private func copyConversation() {
        let text = viewModel.messages.map { msg -> String in
            let role = msg.role == .user ? "You" : (msg.role == .assistant ? "Cortana" : "System")
            return "\(role): \(msg.content)"
        }.joined(separator: "\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Complete Branch

    private func completeBranch() {
        guard let branch = viewModel.branch else { return }
        do {
            // Generate a simple summary from last assistant message
            let lastAssistant = viewModel.messages.last { $0.role == .assistant }
            let summary = lastAssistant.map { msg in
                String(msg.content.prefix(200)) + (msg.content.count > 200 ? "..." : "")
            }
            try TreeStore.shared.updateBranch(branch.id, status: .completed, summary: summary)
            viewModel.load() // Refresh
        } catch {
            viewModel.error = error.localizedDescription
        }
    }
}
