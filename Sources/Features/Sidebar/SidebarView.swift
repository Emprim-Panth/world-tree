import SwiftUI

struct SidebarView: View {
    @StateObject private var viewModel = SidebarViewModel()
    @StateObject private var daemonService = DaemonService.shared
    @EnvironmentObject var appState: AppState
    @State private var showNewTreeSheet = false
    @State private var sessionsExpanded = true
    @State private var newTreeName = ""
    @State private var newTreeProject = ""
    private static let defaultWorkingDir = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Development"
    @State private var newTreeWorkingDir = SidebarView.defaultWorkingDir
    @State private var selectedTemplate: WorkflowTemplate?
    @State private var showTemplatePicker = true

    // Rename tree
    @State private var renameTarget: ConversationTree?
    @State private var renameText = ""
    @State private var showRenameSheet = false

    // New category (for Move to → New Category…)
    @State private var newCategoryName = ""
    @State private var showNewCategorySheet = false
    @State private var movingTreeId: String?

    // Delete confirmation
    @State private var deleteTarget: ConversationTree?
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // Projects section (collapsible)
            ProjectListView()
                .frame(height: 200)

            Divider()

            // Active Sessions (collapsible)
            DisclosureGroup(isExpanded: $sessionsExpanded) {
                AgentListView(showHeader: false)
                    .frame(minHeight: 60, maxHeight: 200)
            } label: {
                HStack(spacing: 6) {
                    Text("Active Sessions")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    let totalSessions = daemonService.activeSessions.count + daemonService.tmuxSessions.count
                    if totalSessions > 0 {
                        Text("\(totalSessions)")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue)
                            .cornerRadius(6)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search trees...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary)
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Tree list
            List(selection: $appState.selectedTreeId) {
                ForEach(viewModel.groupedTrees, id: \.project) { group in
                    Section(group.project) {
                        ForEach(group.trees) { tree in
                            treeRow(tree)
                                .tag(tree.id)
                                .contextMenu { treeContextMenu(tree) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .background(FirstMouseEnabler())

            // New tree button
            Button {
                showNewTreeSheet = true
            } label: {
                Label("New Tree", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Canvas")
        .onAppear {
            viewModel.loadTrees()
            viewModel.startObserving()
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNewTree)) { _ in
            showNewTreeSheet = true
        }
        .sheet(isPresented: $showNewTreeSheet) {
            newTreeSheet
        }
        // Rename sheet
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        // New category sheet (for Move to → New Category…)
        .sheet(isPresented: $showNewCategorySheet) {
            newCategorySheet
        }
        // Delete confirmation alert
        .alert("Delete \"\(deleteTarget?.name ?? "Tree")\"?",
               isPresented: $showDeleteConfirm,
               presenting: deleteTarget) { tree in
            Button("Delete", role: .destructive) {
                viewModel.deleteTree(tree.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { tree in
            Text("This permanently deletes \"\(tree.name)\" and all its messages. This cannot be undone.")
        }
    }

    // MARK: - Tree Row

    private func treeRow(_ tree: ConversationTree) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tree.name)
                    .fontWeight(appState.selectedTreeId == tree.id ? .semibold : .regular)
                Spacer()
                Text("\(tree.messageCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .cornerRadius(4)
            }

            // Show branch tree when selected
            if appState.selectedTreeId == tree.id, !tree.branches.isEmpty {
                ForEach(tree.branches.filter { $0.parentBranchId == nil }) { rootBranch in
                    TreeNodeView(branch: rootBranch, treeId: tree.id)
                        .padding(.leading, 8)
                }
            }
        }
        .onChange(of: appState.selectedTreeId) { _, newId in
            if newId == tree.id {
                loadTreeBranches(tree.id)
            }
        }
    }

    @ViewBuilder
    private func treeContextMenu(_ tree: ConversationTree) -> some View {
        Button("Rename…") {
            renameTarget = tree
            renameText = tree.name
            showRenameSheet = true
        }

        Menu("Move to…") {
            ForEach(viewModel.projectNames.filter { $0 != (tree.project ?? "") }, id: \.self) { project in
                Button(project) {
                    viewModel.moveTree(tree.id, toProject: project)
                }
            }
            if tree.project != nil {
                Button("General (no project)") {
                    viewModel.moveTree(tree.id, toProject: nil)
                }
            }
            Divider()
            Button("New Category…") {
                movingTreeId = tree.id
                newCategoryName = ""
                showNewCategorySheet = true
            }
        }

        Divider()

        Button("Archive") {
            viewModel.archiveTree(tree.id)
        }

        Button("Delete…", role: .destructive) {
            deleteTarget = tree
            showDeleteConfirm = true
        }
    }

    /// Load full tree with branches when selected
    private func loadTreeBranches(_ treeId: String) {
        do {
            if let fullTree = try TreeStore.shared.getTree(treeId) {
                if let idx = viewModel.trees.firstIndex(where: { $0.id == treeId }) {
                    viewModel.trees[idx].branches = fullTree.branches
                }
                // Auto-select root branch if none selected
                if appState.selectedBranchId == nil,
                   let root = fullTree.rootBranch {
                    appState.selectBranch(root.id, in: treeId)
                }
            }
        } catch {
            viewModel.error = error.localizedDescription
        }
    }

    // MARK: - New Tree Sheet

    private var newTreeSheet: some View {
        Group {
            if showTemplatePicker {
                TemplatePicker(
                    onSelect: { template in
                        selectedTemplate = template
                        showTemplatePicker = false
                    },
                    onSkip: {
                        selectedTemplate = nil
                        showTemplatePicker = false
                    }
                )
            } else {
                newTreeForm
            }
        }
    }

    private var newTreeForm: some View {
        VStack(spacing: 16) {
            HStack {
                if let template = selectedTemplate {
                    Image(systemName: template.icon)
                        .foregroundStyle(.cyan)
                    Text("New Tree — \(template.name)")
                        .font(.headline)
                } else {
                    Text("New Conversation Tree")
                        .font(.headline)
                }
                Spacer()
                if selectedTemplate != nil {
                    Button("Change Template") {
                        showTemplatePicker = true
                    }
                    .controlSize(.small)
                }
            }

            TextField("Name", text: $newTreeName)
                .textFieldStyle(.roundedBorder)

            TextField("Project (optional)", text: $newTreeProject)
                .textFieldStyle(.roundedBorder)
                .onChange(of: newTreeProject) { _, newValue in
                    if !newValue.isEmpty {
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        let candidate = "\(home)/Development/\(newValue)"
                        if FileManager.default.fileExists(atPath: candidate) {
                            newTreeWorkingDir = candidate
                        }
                    } else {
                        newTreeWorkingDir = Self.defaultWorkingDir
                    }
                }

            HStack {
                TextField("Working directory", text: $newTreeWorkingDir)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                Button("Browse") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = URL(fileURLWithPath: "\(FileManager.default.homeDirectoryForCurrentUser.path)/Development")
                    if panel.runModal() == .OK, let url = panel.url {
                        newTreeWorkingDir = url.path
                    }
                }
                .controlSize(.small)
            }

            HStack {
                Button("Cancel") {
                    resetNewTreeState()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    let project = newTreeProject.isEmpty ? nil : newTreeProject
                    viewModel.createTree(
                        name: newTreeName,
                        project: project,
                        workingDirectory: newTreeWorkingDir,
                        template: selectedTemplate
                    )
                    showNewTreeSheet = false
                    resetNewTreeState()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newTreeName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func resetNewTreeState() {
        showNewTreeSheet = false
        showTemplatePicker = true
        selectedTemplate = nil
        newTreeName = ""
        newTreeProject = ""
        newTreeWorkingDir = Self.defaultWorkingDir
    }

    // MARK: - Rename Sheet

    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("Rename Tree")
                .font(.headline)

            TextField("Tree name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRename() }

            HStack {
                Button("Cancel") { showRenameSheet = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") { commitRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func commitRename() {
        if let target = renameTarget {
            viewModel.renameTree(target.id, name: renameText)
        }
        showRenameSheet = false
        renameTarget = nil
    }

    // MARK: - New Category Sheet

    private var newCategorySheet: some View {
        VStack(spacing: 16) {
            Text("New Category")
                .font(.headline)

            TextField("Category name", text: $newCategoryName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitNewCategory() }

            HStack {
                Button("Cancel") { showNewCategorySheet = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create & Move") { commitNewCategory() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func commitNewCategory() {
        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, let treeId = movingTreeId {
            viewModel.moveTree(treeId, toProject: name)
        }
        showNewCategorySheet = false
        movingTreeId = nil
        newCategoryName = ""
    }
}

// MARK: - First Mouse Enabler

/// Makes the sidebar List respond to the first click even when the window isn't focused.
/// Without this, clicking a row in an unfocused window requires two clicks: one to focus,
/// one to select.
private struct FirstMouseEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> FirstMouseView { FirstMouseView() }
    func updateNSView(_ nsView: FirstMouseView, context: Context) {}

    class FirstMouseView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
