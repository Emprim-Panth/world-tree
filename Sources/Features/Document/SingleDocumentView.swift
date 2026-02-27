import SwiftUI

/// Full-screen single document view - the main interface
struct SingleDocumentView: View {
    let treeId: String
    @StateObject private var viewModel: SingleDocumentViewModel
    @Environment(AppState.self) private var appState
    @State private var showTerminal = false
    @State private var showTreeMap = false

    /// branchId: if provided, loads that specific branch as the main document.
    /// If nil (or the branch isn't found), falls back to the tree's root branch.
    init(treeId: String, branchId: String? = nil) {
        self.treeId = treeId
        _viewModel = StateObject(wrappedValue: SingleDocumentViewModel(treeId: treeId, branchId: branchId))
    }

    /// The branch whose terminal to show at the bottom.
    /// Prefers the sidebar-selected branch; falls back to this tree's main branch.
    private var activeTerminalBranchId: String {
        appState.selectedBranchId ?? viewModel.mainBranchId
    }

    var body: some View {
        VSplitView {
            // ── Document + branch columns ────────────────────────────────
            ZStack(alignment: .topTrailing) {
                // Main document - full screen
                DocumentEditorView(
                    sessionId: viewModel.mainBranchSessionId,
                    branchId: viewModel.mainBranchId,
                    workingDirectory: viewModel.workingDirectory,
                    parentBranchLayout: viewModel.branchLayout
                )

                // Branch columns slide in from right when created
                if !viewModel.branchLayout.visibleBranches.isEmpty {
                    HStack(spacing: 0) {
                        Spacer()

                        // Side-by-side branch columns
                        ForEach(viewModel.branchLayout.visibleBranches) { branch in
                            VStack(spacing: 0) {
                                // Branch header
                                HStack {
                                    Image(systemName: "arrow.triangle.branch")
                                        .foregroundColor(.blue)
                                    Text(branch.displayTitle)
                                        .font(.headline)
                                    Spacer()
                                    Button(action: { viewModel.closeBranch(branch.id) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Close branch")
                                    .accessibilityHint("Closes this branch column")
                                }
                                .padding(12)
                                .background(Color(nsColor: .controlBackgroundColor))

                                Divider()

                                // Branch document
                                if let sessionId = branch.sessionId {
                                    DocumentEditorView(
                                        sessionId: sessionId,
                                        branchId: branch.id,
                                        workingDirectory: viewModel.workingDirectory,
                                        parentBranchLayout: viewModel.branchLayout
                                    )
                                }
                            }
                            .frame(width: 500)
                            .background(Color(nsColor: .textBackgroundColor))
                            .shadow(color: .black.opacity(0.2), radius: 12, x: -4, y: 0)
                            .transition(.move(edge: .trailing))
                        }
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.branchLayout.visibleBranches.count)
                }
            }
            .frame(minHeight: 200)

            // ── Terminal panel (branch-bound, persistent) ─────────────────
            if showTerminal {
                TerminalPanelView(
                    branchId: activeTerminalBranchId,
                    workingDirectory: viewModel.workingDirectory,
                    onClose: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showTerminal = false
                        }
                    }
                )
                .id(activeTerminalBranchId)
                .frame(minHeight: 160, idealHeight: 300, maxHeight: 600)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbar {
            // Model picker — quick access without opening Settings
            ToolbarItem(placement: .secondaryAction) {
                ModelPickerButton()
            }

            // Tree map — visualize conversation branches
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showTreeMap = true
                } label: {
                    Label("Tree Map", systemImage: "arrow.triangle.branch")
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .help("View conversation tree (⌘⇧T)")
            }

            // Terminal toggle
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showTerminal.toggle()
                    }
                } label: {
                    Label("Claude", systemImage: showTerminal ? "terminal.fill" : "terminal")
                }
                .keyboardShortcut("`", modifiers: .command)
                .help("Open Claude terminal (⌘`)")
            }
        }
        .sheet(isPresented: $showTreeMap) {
            ConversationTreeMapView(
                treeId: treeId,
                currentBranchId: viewModel.mainBranchId,
                onNavigate: { branchId in
                    AppState.shared.selectBranch(branchId, in: treeId)
                }
            )
        }
        .onAppear {
            // Pre-warm the main branch terminal so it's ready when user opens it.
            // Pass the persisted tmux session name so that on app restart we reattach
            // to the exact same tmux session (preserves shell history + running processes).
            BranchTerminalManager.shared.warmUp(
                branchId: viewModel.mainBranchId,
                workingDirectory: viewModel.workingDirectory,
                knownTmuxSession: viewModel.mainBranchTmuxSession
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .canvasServerRequestedTerminalOpen)) { note in
            guard let branchId = note.object as? String else { return }
            // Only respond if the notification targets this tree's main branch
            if branchId == viewModel.mainBranchId || branchId == activeTerminalBranchId {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showTerminal = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNewBranch)) { _ in
            // Route to the main document editor to fork from its last message
            NotificationCenter.default.post(
                name: .forkLastMessage,
                object: viewModel.mainBranchId
            )
        }
        // NOTE: Terminals are intentionally NOT terminated on disappear.
        // BranchTerminalManager owns the PTY processes for their full lifetime —
        // they survive branch switching, sidebar navigation, and view recreation.
        // Terminals are only killed by explicit user action (closeBranch, archive, delete)
        // or at app quit via NSApplication.willTerminateNotification.

    }
}

@MainActor
class SingleDocumentViewModel: ObservableObject {
    let treeId: String
    let mainBranchId: String         // branch.id (used for terminal routing)
    let mainBranchSessionId: String  // branch.sessionId (used for DB queries)
    let mainBranchTmuxSession: String?  // persisted tmux session name (nil on first open)
    /// Cached at init — workingDirectory is immutable after tree creation.
    /// Prevents repeated DB reads on every body re-evaluation.
    let workingDirectory: String
    var branchLayout: BranchLayoutViewModel

    init(treeId: String, branchId: String? = nil) {
        self.treeId = treeId

        // One DB read — reused for both workingDirectory and root branch lookup.
        let cwd = FileManager.default.currentDirectoryPath
        let existingTree = try? TreeStore.shared.getTree(treeId)
        let workDir = existingTree?.workingDirectory
            .flatMap { $0.isEmpty ? nil : $0 } ?? cwd

        // If a specific branchId was requested (e.g., user clicked a branch in sidebar),
        // try to load that branch first. Fall back to root branch if not found.
        let targetBranch: Branch? = branchId.flatMap { id in
            existingTree?.branches.first { $0.id == id }
        }
        let activeBranch = targetBranch ?? existingTree?.rootBranch

        if let branch = activeBranch,
           let sessionId = branch.sessionId {
            // Use the selected or root branch
            self.mainBranchId = branch.id
            self.mainBranchSessionId = sessionId
            self.mainBranchTmuxSession = branch.tmuxSessionName
        } else if let branch = try? TreeStore.shared.createBranch(
            treeId: treeId,
            parentBranch: nil,
            forkFromMessage: nil,
            type: .conversation,
            title: "Main",
            workingDirectory: workDir
        ), let sessionId = branch.sessionId {
            // First open — create the root branch (no tmux session yet)
            self.mainBranchId = branch.id
            self.mainBranchSessionId = sessionId
            self.mainBranchTmuxSession = nil
        } else {
            // Last resort fallback
            let fallbackBranchId = UUID().uuidString
            let sessionId = UUID().uuidString
            try? DatabaseManager.shared.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO sessions (id, terminal_id, working_directory, description, started_at)
                        VALUES (?, ?, ?, ?, datetime('now'))
                        """,
                    arguments: [sessionId, "canvas", workDir, "World Tree Session"]
                )
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO canvas_branches
                        (id, tree_id, session_id, branch_type, title, status, collapsed, created_at, updated_at)
                        VALUES (?, ?, ?, 'conversation', 'Main', 'active', 0, datetime('now'), datetime('now'))
                        """,
                    arguments: [fallbackBranchId, treeId, sessionId]
                )
            }
            self.mainBranchId = fallbackBranchId
            self.mainBranchSessionId = sessionId
            self.mainBranchTmuxSession = nil
        }

        self.workingDirectory = workDir
        self.branchLayout = BranchLayoutViewModel(treeId: treeId)
    }

    func closeBranch(_ branchId: String) {
        branchLayout.visibleBranches.removeAll { $0.id == branchId }
        // Terminate the PTY process so the zsh doesn't accumulate indefinitely
        BranchTerminalManager.shared.terminate(branchId: branchId)
    }
}

// MARK: - Terminal Panel

/// Integrated terminal panel — styled to feel native to Canvas, not bolted-on.
/// Adds a header bar with directory context and a close button above the raw SwiftTerm view.
struct TerminalPanelView: View {
    let branchId: String
    let workingDirectory: String
    let onClose: () -> Void

    private var directoryName: String {
        URL(fileURLWithPath: workingDirectory).lastPathComponent
    }

    private var shortenedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return workingDirectory.replacingOccurrences(of: home, with: "~")
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Integrated header ─────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(directoryName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)

                Text(shortenedPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close terminal (⌘`)")
                .accessibilityLabel("Close terminal")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()
                .opacity(0.4)

            // ── Terminal ──────────────────────────────────────────────────
            BranchTerminalView(
                branchId: branchId,
                workingDirectory: workingDirectory
            )
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 0))
    }
}
