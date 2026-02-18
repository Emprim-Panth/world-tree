import SwiftUI

/// Full-screen single document view - the main interface
struct SingleDocumentView: View {
    let treeId: String
    @StateObject private var viewModel: SingleDocumentViewModel
    @State private var showTerminal = false

    init(treeId: String) {
        self.treeId = treeId
        _viewModel = StateObject(wrappedValue: SingleDocumentViewModel(treeId: treeId))
    }

    var body: some View {
        VSplitView {
            // ── Document + branch columns ────────────────────────────────
            ZStack(alignment: .topTrailing) {
                // Main document - full screen
                DocumentEditorView(
                    sessionId: viewModel.mainBranchSessionId,
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

            // ── Terminal panel ───────────────────────────────────────────
            if showTerminal {
                CanvasLocalTerminal(workingDirectory: viewModel.workingDirectory)
                    .frame(minHeight: 150, idealHeight: 280, maxHeight: 600)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showTerminal.toggle()
                    }
                } label: {
                    Label("Terminal", systemImage: showTerminal ? "terminal.fill" : "terminal")
                }
                .keyboardShortcut("`", modifiers: .command)
                .help("Toggle Terminal (⌘`)")
            }
        }
    }
}

@MainActor
class SingleDocumentViewModel: ObservableObject {
    @Published var activeBranches: [Branch] = []

    let treeId: String
    let mainBranchSessionId: String
    var branchLayout: BranchLayoutViewModel

    init(treeId: String) {
        self.treeId = treeId

        // Create main branch with real database session
        // This creates both a session record and a branch record
        let cwd = FileManager.default.currentDirectoryPath
        if let branch = try? TreeStore.shared.createBranch(
            treeId: treeId,
            parentBranch: nil,
            forkFromMessage: nil,
            type: .conversation,
            title: "Main Conversation",
            workingDirectory: cwd
        ), let sessionId = branch.sessionId {
            self.mainBranchSessionId = sessionId
        } else {
            // Fallback - create session manually if branch creation fails
            let sessionId = UUID().uuidString
            try? DatabaseManager.shared.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO sessions (id, terminal_id, working_directory, description, started_at)
                        VALUES (?, ?, ?, ?, datetime('now'))
                        """,
                    arguments: [sessionId, "canvas", cwd, "Canvas Session"]
                )
            }
            self.mainBranchSessionId = sessionId
        }

        // Initialize branch layout for managing multiple branches
        self.branchLayout = BranchLayoutViewModel(treeId: treeId)
    }

    var workingDirectory: String {
        if let tree = try? TreeStore.shared.getTree(treeId),
           let cwd = tree.workingDirectory, !cwd.isEmpty {
            return cwd
        }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/Development"
    }

    func closeBranch(_ branchId: String) {
        activeBranches.removeAll { $0.id == branchId }
    }

    func addBranch(_ branch: Branch) {
        activeBranches.append(branch)
    }
}
