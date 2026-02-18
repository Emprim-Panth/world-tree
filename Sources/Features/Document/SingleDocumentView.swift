import SwiftUI

/// Full-screen single document view - the main interface
struct SingleDocumentView: View {
    let treeId: String
    @StateObject private var viewModel: SingleDocumentViewModel
    @EnvironmentObject private var appState: AppState
    @State private var showTerminal = false

    init(treeId: String) {
        self.treeId = treeId
        _viewModel = StateObject(wrappedValue: SingleDocumentViewModel(treeId: treeId))
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
                if !viewModel.activeBranches.isEmpty {
                    HStack(spacing: 0) {
                        Spacer()

                        // Side-by-side branch columns
                        ForEach(viewModel.activeBranches) { branch in
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
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.activeBranches.count)
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

            // Terminal toggle
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showTerminal.toggle()
                        if showTerminal {
                            // Pre-type "claude" into the terminal so user just hits Enter.
                            // Task.sleep respects cancellation unlike DispatchQueue.asyncAfter.
                            let branchId = activeTerminalBranchId
                            Task {
                                try? await Task.sleep(nanoseconds: 400_000_000)
                                BranchTerminalManager.shared.send(to: branchId, text: "claude\n")
                            }
                        }
                    }
                } label: {
                    Label("Claude", systemImage: showTerminal ? "terminal.fill" : "terminal")
                }
                .keyboardShortcut("`", modifiers: .command)
                .help("Open Claude terminal (⌘`)")
            }
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
        // NOTE: Terminals are intentionally NOT terminated on disappear.
        // BranchTerminalManager owns the PTY processes for their full lifetime —
        // they survive branch switching, sidebar navigation, and view recreation.
        // Terminals are only killed by explicit user action (closeBranch, archive, delete)
        // or at app quit via NSApplication.willTerminateNotification.
    }
}

@MainActor
class SingleDocumentViewModel: ObservableObject {
    @Published var activeBranches: [Branch] = []

    let treeId: String
    let mainBranchId: String         // branch.id (used for terminal routing)
    let mainBranchSessionId: String  // branch.sessionId (used for DB queries)
    let mainBranchTmuxSession: String?  // persisted tmux session name (nil on first open)
    /// Cached at init — workingDirectory is immutable after tree creation.
    /// Prevents repeated DB reads on every body re-evaluation.
    let workingDirectory: String
    var branchLayout: BranchLayoutViewModel

    init(treeId: String) {
        self.treeId = treeId

        // One DB read — reused for both workingDirectory and root branch lookup.
        let cwd = FileManager.default.currentDirectoryPath
        let existingTree = try? TreeStore.shared.getTree(treeId)
        let workDir = existingTree?.workingDirectory
            .flatMap { $0.isEmpty ? nil : $0 } ?? cwd

        if let root = existingTree?.rootBranch,
           let sessionId = root.sessionId {
            // Reuse the existing root branch and its session
            self.mainBranchId = root.id
            self.mainBranchSessionId = sessionId
            self.mainBranchTmuxSession = root.tmuxSessionName
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
            let branchId = UUID().uuidString
            let sessionId = UUID().uuidString
            try? DatabaseManager.shared.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO sessions (id, terminal_id, working_directory, description, started_at)
                        VALUES (?, ?, ?, ?, datetime('now'))
                        """,
                    arguments: [sessionId, "canvas", workDir, "Canvas Session"]
                )
            }
            self.mainBranchId = branchId
            self.mainBranchSessionId = sessionId
            self.mainBranchTmuxSession = nil
        }

        self.workingDirectory = workDir
        self.branchLayout = BranchLayoutViewModel(treeId: treeId)
    }

    func closeBranch(_ branchId: String) {
        activeBranches.removeAll { $0.id == branchId }
        // Terminate the PTY process so the zsh doesn't accumulate indefinitely
        BranchTerminalManager.shared.terminate(branchId: branchId)
    }

    func addBranch(_ branch: Branch) {
        activeBranches.append(branch)
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
