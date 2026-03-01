import SwiftUI

// MARK: - Sort Order

enum SimpleModeSortOrder: String, CaseIterable {
    case recentDesc = "recentDesc"
    case recentAsc  = "recentAsc"
    case alphaAsc   = "alphaAsc"
    case alphaDesc  = "alphaDesc"

    var label: String {
        switch self {
        case .recentDesc: return "Recently Modified"
        case .recentAsc:  return "Oldest First"
        case .alphaAsc:   return "A → Z"
        case .alphaDesc:  return "Z → A"
        }
    }

    var icon: String {
        switch self {
        case .recentDesc: return "arrow.down.circle"
        case .recentAsc:  return "arrow.up.circle"
        case .alphaAsc:   return "arrow.up.doc"
        case .alphaDesc:  return "arrow.down.doc"
        }
    }
}

// MARK: - ViewModel

@MainActor
final class SimpleModeViewModel: ObservableObject {
    @Published var projects: [CachedProject] = []
    @Published var selectedProject: CachedProject?
    @Published var resolvedTreeId: String?
    @Published var resolvedBranchId: String?
    @Published var isResolving = false
    @Published var error: String?
    @Published var searchText: String = ""
    @Published var sortOrder: SimpleModeSortOrder = {
        guard let raw = UserDefaults.standard.string(forKey: AppConstants.simpleModeSortOrderKey),
              let order = SimpleModeSortOrder(rawValue: raw) else { return .recentDesc }
        return order
    }() {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: AppConstants.simpleModeSortOrderKey) }
    }

    var filteredProjects: [CachedProject] {
        let base = searchText.isEmpty ? projects : projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
        return base.sorted { a, b in
            switch sortOrder {
            case .recentDesc: return a.lastModified > b.lastModified
            case .recentAsc:  return a.lastModified < b.lastModified
            case .alphaAsc:   return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .alphaDesc:  return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedDescending
            }
        }
    }

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
    @Environment(AppState.self) private var appState
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
        VStack(spacing: 0) {
            // Search + Sort header
            HStack(spacing: 6) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Search…", text: $vm.searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(8)
                .frame(maxWidth: .infinity)

                Menu {
                    Section("By Date") {
                        Button { vm.sortOrder = .recentDesc } label: {
                            if vm.sortOrder == .recentDesc { Label("Recently Modified", systemImage: "checkmark") }
                            else { Text("Recently Modified") }
                        }
                        Button { vm.sortOrder = .recentAsc } label: {
                            if vm.sortOrder == .recentAsc { Label("Oldest First", systemImage: "checkmark") }
                            else { Text("Oldest First") }
                        }
                    }
                    Section("By Name") {
                        Button { vm.sortOrder = .alphaAsc } label: {
                            if vm.sortOrder == .alphaAsc { Label("A → Z", systemImage: "checkmark") }
                            else { Text("A → Z") }
                        }
                        Button { vm.sortOrder = .alphaDesc } label: {
                            if vm.sortOrder == .alphaDesc { Label("Z → A", systemImage: "checkmark") }
                            else { Text("Z → A") }
                        }
                    }
                } label: {
                    Image(systemName: vm.sortOrder.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(6)
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Sort: \(vm.sortOrder.label)")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            List(vm.filteredProjects, id: \.path, selection: Binding(
                get: { vm.selectedProject?.path },
                set: { path in
                    if let path, let project = vm.filteredProjects.first(where: { $0.path == path }) {
                        vm.select(project)
                    }
                }
            )) { project in
                projectRow(project)
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("Projects")
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
