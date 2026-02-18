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

    // Rename category
    @State private var renamingCategory: String?
    @State private var renameCategoryText = ""
    @State private var showRenameCategorySheet = false

    // New tree pre-filled for a specific category
    @State private var quickNewTreeProject = ""

    var body: some View {
        VStack(spacing: 0) {
            // Projects section (collapsible)
            ProjectListView()
                .frame(minHeight: 120, maxHeight: 240)

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

            // Tree list — ScrollView instead of List so contextMenu and
            // single-click work correctly (NSTableView eats all mouse events)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.groupedTrees, id: \.project) { group in
                        // Section header — right-click to rename/delete category
                        HStack {
                            Text(group.project)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                quickNewTreeProject = group.project
                                newTreeProject = group.project
                                showNewTreeSheet = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Rename Category…") {
                                renamingCategory = group.project
                                renameCategoryText = group.project
                                showRenameCategorySheet = true
                            }
                            Button("New Tree Here") {
                                quickNewTreeProject = group.project
                                newTreeProject = group.project
                                showNewTreeSheet = true
                            }
                        }

                        ForEach(group.trees) { tree in
                            treeRow(tree)
                                .contextMenu { treeContextMenu(tree) }
                        }
                    }
                }
                .padding(.bottom, 4)
            }

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
        // Rename tree sheet
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        // Rename category sheet
        .sheet(isPresented: $showRenameCategorySheet) {
            renameCategorySheet
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
        let isSelected = appState.selectedTreeId == tree.id
        let isBridge = tree.isTelegramBridge
        let accentColor: Color = isBridge ? .teal : .accentColor

        return HStack(spacing: 8) {
            // Bridge trees get a phone icon; regular trees get nothing
            if isBridge {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.teal)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(tree.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)

                if isBridge {
                    Text("Phone bridge")
                        .font(.caption2)
                        .foregroundStyle(.teal.opacity(0.8))
                }
            }

            Spacer()

            Text("\(tree.messageCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary)
                .cornerRadius(6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isBridge ? 7 : 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? accentColor.opacity(0.18) : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedTreeId = tree.id
            loadTreeBranches(tree.id)
            if appState.selectedBranchId == nil,
               let root = tree.branches.first(where: { $0.parentBranchId == nil }) {
                appState.selectBranch(root.id, in: tree.id)
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

    // MARK: - Rename Category Sheet

    private var renameCategorySheet: some View {
        VStack(spacing: 16) {
            Text("Rename Category")
                .font(.headline)

            TextField("Category name", text: $renameCategoryText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRenameCategory() }

            HStack {
                Button("Cancel") { showRenameCategorySheet = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") { commitRenameCategory() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameCategoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func commitRenameCategory() {
        let newName = renameCategoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, let oldName = renamingCategory else {
            showRenameCategorySheet = false
            return
        }
        // Move every tree in the old category to the new name
        for tree in viewModel.trees where (tree.project ?? "General") == oldName {
            viewModel.moveTree(tree.id, toProject: newName == "General" ? nil : newName)
        }
        showRenameCategorySheet = false
        renamingCategory = nil
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

