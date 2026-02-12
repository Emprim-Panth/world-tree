import SwiftUI

struct ProjectListView: View {
    @StateObject private var viewModel = ProjectListViewModel()
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with refresh button
            HStack {
                Text("Projects")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button {
                    Task {
                        await viewModel.refresh()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isRefreshing)
                .help("Refresh project list")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            Divider()
            
            // Project list
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.projects.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No projects found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("~/Development")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospaced()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.projects, id: \.path) { project in
                            ProjectRowView(
                                project: project,
                                isSelected: appState.selectedProjectPath == project.path,
                                onSelect: {
                                    appState.selectProject(project.path)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 200)
        .onAppear {
            viewModel.startObserving()
            Task {
                await viewModel.loadProjects()
            }
        }
        .onDisappear {
            viewModel.stopObserving()
        }
    }
}

// MARK: - View Model

@MainActor
final class ProjectListViewModel: ObservableObject {
    @Published var projects: [CachedProject] = []
    @Published var isLoading = false
    @Published var isRefreshing = false
    @Published var error: String?
    
    private var observation: Any?
    
    func loadProjects() async {
        isLoading = true
        do {
            projects = try await ProjectRefreshService.shared.getCachedProjects()
            error = nil
        } catch {
            self.error = error.localizedDescription
            canvasLog("[ProjectListVM] Error loading projects: \(error)")
        }
        isLoading = false
    }
    
    func refresh() async {
        isRefreshing = true
        let result = await ProjectRefreshService.shared.refresh()
        
        switch result {
        case .success(let count):
            canvasLog("[ProjectListVM] Refreshed \(count) projects")
            await loadProjects()
        case .failure(let error):
            self.error = error.localizedDescription
        }
        
        isRefreshing = false
    }
    
    func startObserving() {
        observation = NotificationCenter.default.addObserver(
            forName: .projectCacheUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.loadProjects()
            }
        }
    }
    
    func stopObserving() {
        if let obs = observation {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}
