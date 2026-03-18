import SwiftUI

/// Full-screen single document view - the main interface
struct SingleDocumentView: View {
    let treeId: String
    @StateObject private var viewModel: SingleDocumentViewModel
    @Environment(AppState.self) private var appState

    /// branchId: if provided, loads that specific branch as the main document.
    /// If nil (or the branch isn't found), falls back to the tree's root branch.
    init(treeId: String, branchId: String? = nil) {
        self.treeId = treeId
        _viewModel = StateObject(wrappedValue: SingleDocumentViewModel(treeId: treeId, branchId: branchId))
    }

    /// The branch whose terminal to show at the bottom (fallback when no project).
    /// Prefers the sidebar-selected branch; falls back to this tree's main branch.
    private var activeTerminalBranchId: String {
        appState.selectedBranchId ?? viewModel.mainBranchId
    }

    /// Whether this tree is bound to a project (and should use a project-level terminal).
    private var hasProjectTerminal: Bool {
        viewModel.projectName != nil
    }

    /// Persisted terminal panel height — survives branch switches.
    @State private var terminalHeight: CGFloat = 300

    var body: some View {
        // VStack instead of VSplitView — macOS auto-generates a toolbar toggle button
        // for every NSSplitView, which conflicts with our own terminal toggle button
        // (two identical-looking "column" buttons appear at top right, both confusing).
        // A VStack with a custom drag handle gives identical UX without the phantom button.
        VStack(spacing: 0) {
            // ── Main document ────────────────────────────────────────────
            DocumentEditorView(
                sessionId: viewModel.mainBranchSessionId,
                branchId: viewModel.mainBranchId,
                workingDirectory: viewModel.workingDirectory
            )
            .frame(minHeight: 200)

            // ── Terminal panel (project-bound when available, else branch-bound) ──
            if appState.terminalVisible {
                // Drag handle — lets the user resize the terminal panel
                Color.primary.opacity(0.1)
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        Capsule()
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: 32, height: 3)
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let delta = -value.translation.height
                                terminalHeight = max(120, min(700, terminalHeight + delta))
                            }
                    )

                if let project = viewModel.projectName {
                    // Project terminal — persists across branch switches
                    TerminalPanelView(
                        project: project,
                        workingDirectory: viewModel.workingDirectory,
                        onClose: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                appState.terminalVisible = false
                            }
                        }
                    )
                    .id("project-\(project)")
                    .frame(height: terminalHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    // Branch terminal — fallback for workspace trees without a project
                    TerminalPanelView(
                        branchId: activeTerminalBranchId,
                        workingDirectory: viewModel.workingDirectory,
                        onClose: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                appState.terminalVisible = false
                            }
                        }
                    )
                    .id(activeTerminalBranchId)
                    .frame(height: terminalHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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
                        appState.terminalVisible.toggle()
                    }
                } label: {
                    Label("Claude", systemImage: appState.terminalVisible ? "terminal.fill" : "terminal")
                }
                .keyboardShortcut("`", modifiers: .command)
                .help("Open Claude terminal (⌘`)")
            }
        }
        .onAppear {
            BranchTerminalManager.shared.warmUpPreferred(
                branchId: viewModel.mainBranchId,
                project: viewModel.projectName,
                workingDirectory: viewModel.workingDirectory,
                knownTmuxSession: viewModel.mainBranchTmuxSession
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .canvasServerRequestedTerminalOpen)) { note in
            guard let branchId = note.object as? String else { return }
            // Only respond if the notification targets this tree's main branch
            if branchId == viewModel.mainBranchId || branchId == activeTerminalBranchId {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    appState.terminalVisible = true
                }
            }
        }
        // NOTE: Terminals are intentionally NOT terminated on disappear.
        // BranchTerminalManager owns the PTY processes for their full lifetime —
        // they survive branch switching, sidebar navigation, and view recreation.
        // Terminals are only killed by explicit user action (archive, delete)
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
    /// Project name from the tree — nil for workspace trees.
    /// When set, terminal binds to project-level tmux session instead of branch-level.
    let projectName: String?

    init(treeId: String, branchId: String? = nil) {
        self.treeId = treeId

        // One DB read — reused for both workingDirectory and root branch lookup.
        // macOS apps have currentDirectoryPath = "/" which is useless as a working dir.
        // Fall back to ~/Development instead — always a valid, meaningful directory.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallbackCwd = "\(home)/Development"
        let existingTree = try? TreeStore.shared.getTree(treeId)
        let workDir = existingTree?.workingDirectory
            .flatMap { $0.isEmpty || $0 == "/" ? nil : $0 } ?? fallbackCwd

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
            do { try DatabaseManager.shared.write { db in
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
            } } catch {
                wtLog("[SingleDocumentView] Last-resort fallback DB write failed for tree \(treeId): \(error)")
            }
            self.mainBranchId = fallbackBranchId
            self.mainBranchSessionId = sessionId
            self.mainBranchTmuxSession = nil
        }

        self.workingDirectory = workDir
        self.projectName = existingTree?.project
    }
}

// MARK: - Terminal Panel

/// Integrated terminal panel — styled to feel native to Canvas, not bolted-on.
/// Supports both project-level terminals (wt-{project}) and branch-level terminals (canvas-{branch}).
/// Project terminals persist across branch switches; branch terminals are the fallback.
struct TerminalPanelView: View {
    /// Project name — when set, uses project-level terminal. Mutually exclusive with branchId.
    let project: String?
    /// Branch ID — fallback when no project is set.
    let branchId: String?
    let workingDirectory: String
    let onClose: () -> Void
    @ObservedObject private var terminalManager = BranchTerminalManager.shared

    /// Project-mode initializer — uses wt-{project} tmux session.
    init(project: String, workingDirectory: String, onClose: @escaping () -> Void) {
        self.project = project
        self.branchId = nil
        self.workingDirectory = workingDirectory
        self.onClose = onClose
    }

    /// Branch-mode initializer — uses canvas-{branchId} tmux session.
    init(branchId: String, workingDirectory: String, onClose: @escaping () -> Void) {
        self.project = nil
        self.branchId = branchId
        self.workingDirectory = workingDirectory
        self.onClose = onClose
    }

    private var headerLabel: String {
        if let project { return project }
        return URL(fileURLWithPath: workingDirectory).lastPathComponent
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

                Text(headerLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)

                Text(shortenedPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer()

                if project != nil {
                    Text("project")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.cyan.opacity(0.1))
                        .clipShape(Capsule())
                }

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
            // .id() includes terminalVersions — when the watchdog detects a dead session
            // and increments the version, SwiftUI recreates the view and makeNSView fires,
            // pulling a fresh CapturingTerminalView (and new PTY) from BranchTerminalManager.
            if let project {
                ProjectTerminalView(
                    project: project,
                    workingDirectory: workingDirectory
                )
                .id("project-\(project)-\(terminalManager.terminalVersions["project-\(project)"] ?? 0)")
            } else if let branchId {
                BranchTerminalView(
                    branchId: branchId,
                    workingDirectory: workingDirectory
                )
                .id("\(branchId)-\(terminalManager.terminalVersions[branchId] ?? 0)")
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 0))
    }
}
