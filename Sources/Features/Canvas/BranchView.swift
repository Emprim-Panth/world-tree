import SwiftUI

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
                    onNavigateToParent: {
                        if let parentId = branch.parentBranchId {
                            appState.selectBranch(parentId, in: branch.treeId)
                        }
                    },
                    onComplete: {
                        completeBranch()
                    }
                )
                Divider()
            }

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Summary card if branch has completed children
                        completedChildSummaries

                        ForEach(viewModel.messages) { message in
                            MessageRow(message: message) { msg, type in
                                forkSourceMessage = msg
                                forkType = type
                                showForkSheet = true
                            }
                            .id(message.id)
                        }

                        // Streaming response
                        if viewModel.isResponding && !viewModel.streamingResponse.isEmpty {
                            streamingResponseView
                                .id("streaming")
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: viewModel.streamingResponse) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            Divider()

            // Input
            if viewModel.branch?.status == .active {
                inputBar
            } else if let branch = viewModel.branch {
                HStack {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text("Branch \(branch.status.rawValue)")
                        .foregroundStyle(.secondary)
                }
                .padding()
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
    }

    // MARK: - Streaming Response

    private var streamingResponseView: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "diamond.fill")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                    Text("Cortana")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView()
                        .controlSize(.mini)
                }

                // Tool activity indicators
                if !viewModel.toolActivities.isEmpty {
                    ForEach(viewModel.toolActivities) { activity in
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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                    }
                }

                // Streaming text
                if !viewModel.streamingResponse.isEmpty {
                    Text(viewModel.streamingResponse)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(12)
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            Spacer(minLength: 80)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if viewModel.isResponding {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("streaming", anchor: .bottom)
            }
        } else if let lastId = viewModel.messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if viewModel.isResponding {
                // Show cancel button while Cortana is responding
                Button {
                    viewModel.cancelResponse()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .foregroundStyle(.red)
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
        .padding(12)
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
