import SwiftUI

struct SidebarView: View {
    @StateObject private var viewModel = SidebarViewModel()
    @StateObject private var daemonService = DaemonService.shared
    @EnvironmentObject var appState: AppState
    @State private var showNewTreeSheet = false
    @State private var sessionsExpanded = false
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

    // Delete tree confirmation
    @State private var deleteTarget: ConversationTree?
    @State private var showDeleteConfirm = false

    // Delete/archive project confirmation
    @State private var deleteProjectTarget: String?
    @State private var showDeleteProjectConfirm = false

    // Rename category
    @State private var renamingCategory: String?
    @State private var renameCategoryText = ""
    @State private var showRenameCategorySheet = false

    // New tree pre-filled for a specific category
    @State private var quickNewTreeProject = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search…", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(8)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Search scope toggle — only visible when there's a query
            if !viewModel.searchText.isEmpty {
                HStack(spacing: 4) {
                    ForEach(SearchScope.allCases, id: \.self) { scope in
                        Button {
                            viewModel.searchScope = scope
                        } label: {
                            Text(scope.rawValue)
                                .font(.caption2)
                                .fontWeight(viewModel.searchScope == scope ? .semibold : .regular)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(viewModel.searchScope == scope
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.primary.opacity(0.06))
                                .foregroundStyle(viewModel.searchScope == scope ? Color.accentColor : Color.secondary)
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if viewModel.isSearching {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }

            // Unified project list — projects ARE the grouping, trees live inside them
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Active jobs indicator — only visible when jobs are running
                    ActiveJobsSection()

                    // Content search results
                    if viewModel.searchScope == .content && !viewModel.searchText.isEmpty {
                        if viewModel.contentResults.isEmpty && !viewModel.isSearching {
                            Text("No results")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 24)
                        } else {
                            ForEach(viewModel.contentResults) { result in
                                contentResultRow(result)
                            }
                        }
                    }

                    // Normal tree list (hidden when content search is active)
                    if viewModel.searchScope != .content || viewModel.searchText.isEmpty {
                        ForEach(viewModel.allProjectGroups, id: \.project) { group in
                            // Project header row (replaces old plain text label)
                            ProjectGroupHeader(
                                projectName: group.project,
                                resolvedPath: viewModel.resolvedPath(for: group.project),
                                gitInfo: viewModel.gitInfo(for: group.project),
                                typeIcon: viewModel.typeIcon(for: group.project),
                                treeCount: group.trees.count,
                                onNewTree: {
                                    quickNewTreeProject = group.project
                                    newTreeProject = group.project
                                    if let path = viewModel.resolvedPath(for: group.project) {
                                        newTreeWorkingDir = path
                                    }
                                    showNewTreeSheet = true
                                },
                                onRename: {
                                    renamingCategory = group.project
                                    renameCategoryText = group.project
                                    showRenameCategorySheet = true
                                },
                                onPathChanged: { newPath in
                                    viewModel.updateProjectPath(projectName: group.project, path: newPath)
                                },
                                onArchive: {
                                    viewModel.archiveProject(group.project)
                                },
                                onDelete: {
                                    deleteProjectTarget = group.project
                                    showDeleteProjectConfirm = true
                                }
                            )

                            ForEach(group.trees) { tree in
                                treeRow(tree)
                                    .contextMenu { treeContextMenu(tree) }

                                // Show branches under the selected tree
                                if appState.selectedTreeId == tree.id {
                                    ForEach(tree.branches) { branch in
                                        TreeNodeView(branch: branch, treeId: tree.id)
                                            .padding(.leading, 12)
                                    }
                                }
                            }

                            Spacer().frame(height: 4)
                        }
                    }
                }
                .padding(.bottom, 8)
            }

            Divider()

            // Active Sessions — collapsed by default, bottom of sidebar
            DisclosureGroup(isExpanded: $sessionsExpanded) {
                AgentListView(showHeader: false)
                    .frame(minHeight: 40, maxHeight: 180)
            } label: {
                HStack(spacing: 6) {
                    Text("Sessions")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    let total = daemonService.activeSessions.count + daemonService.tmuxSessions.count
                    if total > 0 {
                        Text("\(total)")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue)
                            .cornerRadius(6)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Bottom action bar: New Tree + New Project
            HStack(spacing: 0) {
                Button {
                    showNewTreeSheet = true
                } label: {
                    Label("New Tree", systemImage: "plus.circle")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                Divider().frame(height: 24)

                Button {
                    // Open new tree sheet with project field pre-focused
                    newTreeProject = ""
                    newTreeName = ""
                    showTemplatePicker = false
                    showNewTreeSheet = true
                } label: {
                    Label("New Project", systemImage: "folder.badge.plus")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .help("Create a new project and tree")
            }
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
        // Delete tree confirmation alert
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
        // Delete project confirmation alert
        .alert("Delete Project \"\(deleteProjectTarget ?? "")\"?",
               isPresented: $showDeleteProjectConfirm) {
            Button("Delete All", role: .destructive) {
                if let name = deleteProjectTarget {
                    viewModel.deleteProject(name)
                }
                deleteProjectTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteProjectTarget = nil }
        } message: {
            Text("This permanently deletes all trees and messages in \"\(deleteProjectTarget ?? "")\".\nThis cannot be undone.")
        }
    }

    // MARK: - Content Search Result Row

    private func contentResultRow(_ result: MessageSearchResult) -> some View {
        let isSelected = appState.selectedTreeId == result.treeId
        return HStack(spacing: 8) {
            Image(systemName: result.role == .user ? "person.circle" : "cpu")
                .font(.caption2)
                .foregroundStyle(result.role == .user ? Color.blue : Color.purple)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.treeName)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(result.snippet)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectBranch(result.branchId, in: result.treeId)
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
                } else if let snippet = tree.lastMessageSnippet, !snippet.isEmpty {
                    // Context trail: what was being worked on
                    Text(snippet.contextSnippet)
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
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
            // Reset branch selection so the new tree always opens at its root.
            // Without this, the previous tree's branchId stays in AppState and the
            // wrong conversation appears in the detail pane.
            appState.selectedBranchId = nil
            appState.selectedTreeId = tree.id
            loadTreeBranches(tree.id)
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

    /// Load full tree with branches when selected — always selects root branch.
    private func loadTreeBranches(_ treeId: String) {
        do {
            if let fullTree = try TreeStore.shared.getTree(treeId) {
                // Cache branches so they survive GRDB observation refreshes.
                viewModel.cacheBranches(fullTree.branches, for: treeId)
                // Always select root branch when switching trees so the canvas
                // opens the correct conversation (not a leftover from the previous tree).
                if let root = fullTree.rootBranch {
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
                .disabled(newTreeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

// MARK: - Project Group Header

struct ProjectGroupHeader: View {
    let projectName: String
    let resolvedPath: String?
    let gitInfo: String?
    let typeIcon: String
    let treeCount: Int
    let onNewTree: () -> Void
    let onRename: () -> Void
    let onPathChanged: (String) -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    @State private var isEditingPath = false
    @State private var editingText = ""

    private var shortenedPath: String {
        guard let path = resolvedPath else { return "No path set" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: home, with: "~")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Name row: icon + name + git badge + tree count + new button
            HStack(spacing: 5) {
                Image(systemName: typeIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 13)

                Text(projectName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let git = gitInfo {
                    Text(git)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .cornerRadius(3)
                }

                Spacer()

                if treeCount > 0 {
                    Text("\(treeCount)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Button(action: onNewTree) {
                    Image(systemName: "plus")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New tree in \(projectName)")
            }

            // Path row: tap to edit inline
            Group {
                if isEditingPath {
                    TextField("Path", text: $editingText)
                        .font(.system(size: 9.5, design: .monospaced))
                        .textFieldStyle(.plain)
                        .foregroundStyle(.secondary)
                        .onSubmit { commitPath() }
                        .onExitCommand { isEditingPath = false }
                } else {
                    Text(shortenedPath)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(resolvedPath == nil ? Color.red.opacity(0.7) : Color.secondary.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help("Click to edit path")
                        .onTapGesture {
                            editingText = resolvedPath ?? ""
                            isEditingPath = true
                        }
                }
            }
            .padding(.leading, 18)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .contextMenu {
            Button("Rename…", action: onRename)
            Divider()
            Button("Archive Project") { onArchive() }
            Button("Delete Project…", role: .destructive) { onDelete() }
        }
    }

    private func commitPath() {
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onPathChanged(trimmed)
        }
        isEditingPath = false
    }
}

// MARK: - String Helper

private extension String {
    /// Clean a raw message for use as a sidebar context trail snippet.
    /// Strips markdown headers, code fences, and truncates to ~65 chars.
    var contextSnippet: String {
        var s = self
            .replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "```[\\s\\S]*?```", with: "…", options: .regularExpression)
            .replacingOccurrences(of: "`[^`]+`", with: "…", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse whitespace
        s = s.components(separatedBy: .newlines).joined(separator: " ")
        return s.count > 65 ? String(s.prefix(62)) + "…" : s
    }
}

