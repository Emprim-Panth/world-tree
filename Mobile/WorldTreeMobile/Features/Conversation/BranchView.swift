import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct BranchView: View {
    @Environment(WorldTreeStore.self) private var store
    @Environment(ConnectionManager.self) private var connectionManager
    @AppStorage(Constants.UserDefaultsKeys.messageFontSize) private var messageFontSize = Constants.Defaults.messageFontSize

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
                    if store.messages.isEmpty, let tree = store.currentTree {
                        store.isLoadingHistory = true
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
                guard let newId, let tree = store.currentTree else { return }
                // For genuine branch switches, set the loading flag here.
                // For initial load (oldId == nil), onAppear handles it.
                if oldId != nil {
                    store.isLoadingHistory = true
                }
                Task {
                    await connectionManager.send(.subscribe(treeId: tree.id, branchId: newId))
                    await connectionManager.send(.loadHistory(branchId: newId))
                }
            }
            .onChange(of: connectionManager.state) { _, newState in
                // Re-subscribe after reconnect — the server loses subscriptions on disconnect.
                if case .connected = newState,
                   let tree = store.currentTree,
                   let branch = store.currentBranch {
                    Task { await connectionManager.send(.subscribe(treeId: tree.id, branchId: branch.id)) }
                }
            }
            .onChange(of: messageText) { _, newText in
                if let id = currentBranchId {
                    store.saveDraft(newText, for: id)
                }
            }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if store.isLoadingHistory && store.messages.isEmpty {
                    ProgressView("Loading messages…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 80)
                }
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.messages) { message in
                        MessageBubble(
                            message: message,
                            fontSize: messageFontSize,
                            onCopy: {
                                #if canImport(UIKit)
                                UIPasteboard.general.string = message.content
                                #endif
                            },
                            onBranch: message.id.hasPrefix("optimistic-") ? nil : {
                                branchFromMessage(message)
                            }
                        )
                        .id(message.id)
                    }
                    if store.serverSeen {
                        SeenIndicator()
                            .id("seen-indicator")
                        ThinkingBubble()
                            .padding(.horizontal)
                            .id("thinking")
                    } else if store.isStreaming {
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
            .onChange(of: store.serverSeen) {
                if store.serverSeen {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
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
        store.saveDraft("", for: branch.id)
        // Show the user's own message immediately — don't wait for the server to echo it back.
        store.addOptimisticMessage(content: content)
        Task { await connectionManager.send(.sendMessage(branchId: branch.id, content: content)) }
    }

    private func stopStreaming() {
        guard let branch = store.currentBranch else { return }
        Task { await connectionManager.send(.cancelStream(branchId: branch.id)) }
    }

    private func branchFromMessage(_ message: Message) {
        guard let tree = store.currentTree, let branch = store.currentBranch else { return }
        let title = String(message.content.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        store.pendingNavigateToNewBranch = true
        Task {
            await connectionManager.send(.createBranch(
                treeId: tree.id,
                fromMessageId: message.id,
                parentBranchId: branch.id,
                title: title.isEmpty ? nil : title
            ))
        }
    }
}

private struct MessageBubble: View {
    let message: Message
    let fontSize: Double
    let onCopy: () -> Void
    /// nil = disable branch option (e.g. optimistic messages that have no server-side ID yet)
    let onBranch: (() -> Void)?

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
                .contextMenu {
                    Button(action: onCopy) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    if let onBranch {
                        Button(action: onBranch) {
                            Label("Branch from here", systemImage: "arrow.triangle.branch")
                        }
                    }
                }
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

// MARK: - Seen Indicator

/// "Seen ✓✓" label shown right-aligned below the last user message while the server
/// has acknowledged receipt but hasn't started streaming yet.
private struct SeenIndicator: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .padding(.leading, -4)
            Text("Seen")
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundStyle(Color.blue.opacity(0.75))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 20)
        .padding(.top, -4)
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
    }
}

// MARK: - Thinking Bubble

/// Animated "thinking…" indicator shown while the server is processing but hasn't
/// sent any tokens yet. Disappears when the first token arrives.
private struct ThinkingBubble: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .scaleEffect(animating ? 1.0 : 0.6)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever()
                            .delay(Double(i) * 0.18),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondarySystemBackground, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animating = true }
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
    }
}

// MARK: - Color helpers

private extension Color {
    static let secondarySystemBackground = Color(uiColor: .secondarySystemBackground)
}
