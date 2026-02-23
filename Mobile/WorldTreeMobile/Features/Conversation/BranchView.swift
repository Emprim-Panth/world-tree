import SwiftUI

struct BranchView: View {
    @Environment(WorldTreeStore.self) private var store
    @Environment(ConnectionManager.self) private var connectionManager
    @AppStorage(Constants.UserDefaultsKeys.messageFontSize) private var messageFontSize = Constants.Defaults.messageFontSize

    // TASK-023: draft text is keyed by branchId in the store, not local @State.
    // We mirror it through a local @State so the TextField binding works efficiently,
    // and sync back to the store on every change.
    @State private var messageText = ""
    private var currentBranchId: String? { store.currentBranch?.id }

    var body: some View {
        let placeholder = store.currentBranch.map { "Message \($0.displayName)…" } ?? "Message…"
        messageList
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MessageInputView(
                    text: $messageText,
                    placeholder: placeholder,
                    isBusy: store.isStreaming,
                    onSend: sendMessage,
                    onStop: stopStreaming
                )
            }
            .onAppear {
                if let id = currentBranchId {
                    messageText = store.draft(for: id)
                    // Load history when messages are absent (session restore path).
                    if store.messages.isEmpty, let tree = store.currentTree {
                        Task {
                            await connectionManager.send(.subscribe(treeId: tree.id, branchId: id))
                            await connectionManager.send(.loadHistory(branchId: id))
                        }
                    }
                }
            }
            .onChange(of: store.currentBranch?.id) { oldId, newId in
                // Save draft for the branch we're leaving.
                if let old = oldId {
                    store.saveDraft(messageText, for: old)
                }
                // Restore draft for the branch we're entering.
                messageText = newId.map { store.draft(for: $0) } ?? ""
            }
            .onChange(of: messageText) { _, newText in
                // Keep the store draft in sync as the user types.
                if let id = currentBranchId {
                    store.saveDraft(newText, for: id)
                }
            }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.messages) { message in
                        MessageBubble(message: message, fontSize: messageFontSize)
                            .id(message.id)
                    }
                    if store.isStreaming {
                        // Tool chips appear above the streaming bubble
                        if !store.activeToolChips.isEmpty {
                            ToolChipsRow(chips: store.activeToolChips)
                                .padding(.horizontal)
                                .id("toolchips")
                        }
                        if !store.streamingText.isEmpty {
                            StreamingBubble(text: store.streamingText)
                                .id("streaming")
                        }
                    }
                }
                .padding()
            }
            .onChange(of: store.messages.count) {
                if let last = store.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: store.streamingText) {
                if store.isStreaming {
                    withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
                }
            }
            .onChange(of: store.activeToolChips.count) {
                if store.isStreaming {
                    withAnimation { proxy.scrollTo("toolchips", anchor: .bottom) }
                }
            }
        }
    }

    private func sendMessage() {
        guard let branch = store.currentBranch,
              !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let content = messageText
        messageText = ""
        // Clear the persisted draft — message was sent.
        store.saveDraft("", for: branch.id)
        Task { await connectionManager.send(.sendMessage(branchId: branch.id, content: content)) }
    }

    private func stopStreaming() {
        guard let branch = store.currentBranch else { return }
        Task { await connectionManager.send(.cancelStream(branchId: branch.id)) }
    }
}

private struct MessageBubble: View {
    let message: Message
    let fontSize: Double

    var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            Text(message.content)
                .font(.system(size: fontSize))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isUser ? Color.blue : Color.secondarySystemBackground, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(isUser ? .white : .primary)
            if !isUser { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

private struct StreamingBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Text(text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondarySystemBackground, in: RoundedRectangle(cornerRadius: 16))
            ProgressView()
                .scaleEffect(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tool Chips

/// Horizontal row of tool execution status chips shown during streaming.
private struct ToolChipsRow: View {
    let chips: [ToolChip]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    ToolChipBadge(chip: chip)
                }
            }
        }
    }
}

private struct ToolChipBadge: View {
    let chip: ToolChip

    var body: some View {
        HStack(spacing: 4) {
            stateIcon
            Text(chip.toolName)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundColor, in: Capsule())
        .foregroundStyle(foregroundColor)
        .animation(.easeInOut(duration: 0.2), value: chip.state)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch chip.state {
        case .running:
            ProgressView()
                .scaleEffect(0.55)
                .frame(width: 12, height: 12)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
        }
    }

    private var backgroundColor: Color {
        switch chip.state {
        case .running: return Color.blue.opacity(0.12)
        case .done:    return Color.green.opacity(0.12)
        case .failed:  return Color.red.opacity(0.12)
        }
    }

    private var foregroundColor: Color {
        switch chip.state {
        case .running: return .blue
        case .done:    return .green
        case .failed:  return .red
        }
    }
}

// MARK: - Color helpers

private extension Color {
    static let secondarySystemBackground = Color(uiColor: .secondarySystemBackground)
}
