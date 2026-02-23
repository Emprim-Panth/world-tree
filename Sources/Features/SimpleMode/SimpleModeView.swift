import SwiftUI

// MARK: - ViewModel

@MainActor
final class SimpleModeViewModel: ObservableObject {
    @Published var projects: [CachedProject] = []
    @Published var selectedProject: CachedProject?
    @Published var resolvedTreeId: String?
    @Published var resolvedBranchId: String?
    @Published var isResolving = false
    @Published var error: String?

    private var projectObserver: NSObjectProtocol?

    init() {
        loadProjects()
        projectObserver = NotificationCenter.default.addObserver(
            forName: .projectCacheUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.loadProjects()
            }
        }
    }

    deinit {
        if let obs = projectObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func loadProjects() {
        projects = (try? ProjectCache().getAll()) ?? []
        // If no project selected yet, pick the first
        if selectedProject == nil, let first = projects.first {
            select(first)
        }
    }

    func select(_ project: CachedProject) {
        guard selectedProject?.path != project.path else { return }
        // Defer mutations off the current view-update pass to avoid
        // "Publishing changes from within view updates" runtime warnings.
        Task { @MainActor in
            self.selectedProject = project
            self.resolvedTreeId = nil
            self.resolvedBranchId = nil
            self.isResolving = true
            self.error = nil
            do {
                let result = try await SimpleProjectStore.shared.resolve(for: project)
                self.resolvedTreeId = result.treeId
                self.resolvedBranchId = result.branchId
            } catch {
                self.error = error.localizedDescription
            }
            self.isResolving = false
        }
    }
}

// MARK: - View

struct SimpleModeView: View {
    @StateObject private var vm = SimpleModeViewModel()
    @EnvironmentObject private var appState: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            detail
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(vm.projects, id: \.path, selection: Binding(
            get: { vm.selectedProject?.path },
            set: { path in
                if let path, let project = vm.projects.first(where: { $0.path == path }) {
                    vm.select(project)
                }
            }
        )) { project in
            projectRow(project)
        }
        .navigationTitle("Projects")
        .listStyle(.sidebar)
    }

    private func projectRow(_ project: CachedProject) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: project.type.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(project.name)
                    .fontWeight(.medium)
            }
            if let branch = project.gitBranch {
                Text(project.gitDirty ? "\(branch) ⚡" : branch)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 20)
            }
        }
        .padding(.vertical, 2)
        .tag(project.path)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if vm.isResolving {
            ProgressView("Loading project…")
        } else if let error = vm.error {
            ContentUnavailableView(
                "Could not open project",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if let treeId = vm.resolvedTreeId {
            let branchId = vm.resolvedBranchId ?? ""
            SingleDocumentView(treeId: treeId, branchId: vm.resolvedBranchId)
                .id("\(treeId)-\(branchId)")
        } else if vm.projects.isEmpty {
            ContentUnavailableView(
                "No Projects Found",
                systemImage: "folder",
                description: Text("Add a development directory in Settings → Connection so World Tree can find your projects.")
            )
        } else {
            ContentUnavailableView(
                "Select a Project",
                systemImage: "sidebar.left",
                description: Text("Choose a project from the sidebar to open its conversation.")
            )
        }
    }
}
