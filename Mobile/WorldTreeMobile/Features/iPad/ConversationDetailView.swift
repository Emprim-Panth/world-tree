import SwiftUI

/// iPad detail column: the active conversation with message list and input.
struct ConversationDetailView: View {
    @Environment(WorldTreeStore.self) private var store
    @Environment(ConnectionManager.self) private var connectionManager

    @AppStorage(Constants.UserDefaultsKeys.messageFontSize)
    private var messageFontSize = Constants.Defaults.iPadMessageFontSize

    @State private var messageText = ""
    private var currentBranchId: String? { store.currentBranch?.id }

    var body: some View {
        GeometryReader { geometry in
            let detailWidth = geometry.size.width
            let userMaxWidth = min(
                detailWidth * DesignTokens.Layout.userBubbleMaxWidthFraction,
                DesignTokens.Layout.bubbleAbsoluteMaxWidth
            )
            let assistantMaxWidth = min(
                detailWidth * DesignTokens.Layout.assistantBubbleMaxWidthFraction,
                DesignTokens.Layout.bubbleAbsoluteMaxWidth
            )

            VStack(spacing: 0) {
                // Reconnect banner at top
                ReconnectBanner()
                    .animation(.easeInOut(duration: 0.3), value: connectionManager.state == .connected)

                if store.currentBranch == nil {
                    // No branch selected
                    ContentUnavailableView(
                        "Select a Branch",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Choose a branch from the center column.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.messages.isEmpty && !store.isStreaming {
                    // Branch selected but empty
                    ContentUnavailableView(
                        "Empty Branch",
                        systemImage: "text.bubble",
                        description: Text("Send a message to start the conversation.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    messageList(userMaxWidth: userMaxWidth, assistantMaxWidth: assistantMaxWidth)
                }

                // Input bar — constrained and centered
                if store.currentBranch != nil {
                    let placeholder = store.currentBranch.map { "Message \($0.displayName)…" } ?? "Message…"
                    HStack {
                        Spacer()
                        MessageInputView(
                            text: $messageText,
                            placeholder: placeholder,
                            isBusy: store.isStreaming,
                            onSend: sendMessage,
                            onStop: stopStreaming
                        )
                        .frame(maxWidth: DesignTokens.Layout.inputBarMaxWidth)
                        Spacer()
                    }
                }
            }
        }
        .onAppear {
            if let id = currentBranchId {
                messageText = store.draft(for: id)
                if store.messages.isEmpty, let tree = store.currentTree {
                    Task {
                        await connectionManager.send(.subscribe(treeId: tree.id, branchId: id))
                        await connectionManager.send(.loadHistory(branchId: id))
                    }
                }
            }
        }
        .onChange(of: store.currentBranch?.id) { oldId, newId in
            if let old = oldId {
                store.saveDraft(messageText, for: old)
            }
            messageText = newId.map { store.draft(for: $0) } ?? ""
        }
        .onChange(of: messageText) { _, newText in
            if let id = currentBranchId {
                store.saveDraft(newText, for: id)
            }
        }
        .keyboardShortcut(.return, modifiers: .command)
    }

    // MARK: - Message List

    private func messageList(userMaxWidth: CGFloat, assistantMaxWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    ForEach(store.messages) { message in
                        let maxW = message.role == "user" ? userMaxWidth : assistantMaxWidth
                        iPadMessageBubble(message: message, maxWidth: maxW, fontSize: messageFontSize)
                            .id(message.id)
                    }

                    if store.isStreaming {
                        if !store.activeToolChips.isEmpty {
                            iPadToolChipsRow(chips: store.activeToolChips)
                                .padding(.horizontal)
                                .id("toolchips")
                        }
                        if !store.streamingText.isEmpty {
                            iPadStreamingBubble(
                                text: store.streamingText,
                                maxWidth: assistantMaxWidth,
                                fontSize: messageFontSize
                            )
                            .id("streaming")
                        }
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
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

    // MARK: - Actions

    private func sendMessage() {
        guard let branch = store.currentBranch,
              !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let content = messageText
        messageText = ""
        store.saveDraft("", for: branch.id)
        Task { await connectionManager.send(.sendMessage(branchId: branch.id, content: content)) }
    }

    private func stopStreaming() {
        guard let branch = store.currentBranch else { return }
        Task { await connectionManager.send(.cancelStream(branchId: branch.id)) }
    }
}

// MARK: - iPad Streaming Bubble

private struct iPadStreamingBubble: View {
    let text: String
    let maxWidth: CGFloat
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("Assistant")
                .font(.caption)
                .foregroundStyle(DesignTokens.Color.brandAsh)
                .padding(.horizontal, DesignTokens.Spacing.xs)

            HStack(alignment: .bottom, spacing: DesignTokens.Spacing.xs) {
                Text(text)
                    .font(.system(size: fontSize))
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                    .background(
                        DesignTokens.Color.brandRoot,
                        in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.bubble)
                    )
                    .foregroundStyle(DesignTokens.Color.brandParchment)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - iPad Tool Chips Row

private struct iPadToolChipsRow: View {
    let chips: [ToolChip]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(chips) { chip in
                    iPadToolChipBadge(chip: chip)
                }
            }
        }
    }
}

private struct iPadToolChipBadge: View {
    let chip: ToolChip

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            stateIcon
            Text(chip.toolName)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
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

// MARK: - ConnectionManager.State Equatable helper

private extension ConnectionManager.State {
    static func == (lhs: ConnectionManager.State, rhs: Bool) -> Bool {
        if case .connected = lhs { return rhs }
        return !rhs
    }
}
