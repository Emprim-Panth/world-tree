import SwiftUI

struct SidebarView: View {
    @StateObject private var viewModel = SidebarViewModel()
    @EnvironmentObject var appState: AppState
    @State private var showNewTreeSheet = false
    @State private var newTreeName = ""
    @State private var newTreeProject = ""
    @State private var newTreeWorkingDir = ""

    var body: some View {
        VStack(spacing: 0) {
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
                        }
                    }
                }
            }
            .listStyle(.sidebar)

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
        .contextMenu {
            Button("Archive") {
                viewModel.archiveTree(tree.id)
            }
        }
        .onChange(of: appState.selectedTreeId) { _, newId in
            if newId == tree.id {
                loadTreeBranches(tree.id)
            }
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
        VStack(spacing: 16) {
            Text("New Conversation Tree")
                .font(.headline)

            TextField("Name", text: $newTreeName)
                .textFieldStyle(.roundedBorder)

            TextField("Project (optional)", text: $newTreeProject)
                .textFieldStyle(.roundedBorder)
                .onChange(of: newTreeProject) { _, newValue in
                    // Auto-fill working directory from project name
                    if !newValue.isEmpty && newTreeWorkingDir.isEmpty {
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        let candidate = "\(home)/Development/\(newValue)"
                        if FileManager.default.fileExists(atPath: candidate) {
                            newTreeWorkingDir = candidate
                        }
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
                    showNewTreeSheet = false
                    newTreeName = ""
                    newTreeProject = ""
                    newTreeWorkingDir = ""
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    let project = newTreeProject.isEmpty ? nil : newTreeProject
                    let cwd = newTreeWorkingDir.isEmpty ? nil : newTreeWorkingDir
                    viewModel.createTree(name: newTreeName, project: project, workingDirectory: cwd)
                    showNewTreeSheet = false
                    newTreeName = ""
                    newTreeProject = ""
                    newTreeWorkingDir = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newTreeName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
