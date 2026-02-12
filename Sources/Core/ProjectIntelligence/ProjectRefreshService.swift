import Foundation

/// Service that periodically scans projects and updates cache
/// Runs in background, can be triggered manually
@MainActor
final class ProjectRefreshService {
    static let shared = ProjectRefreshService()
    
    private let scanner = ProjectScanner()
    private let cache = ProjectCache()
    private var timer: Timer?
    private var isRefreshing = false
    
    private init() {}
    
    /// Start automatic refresh (every 5 minutes)
    func startAutoRefresh(interval: TimeInterval = 300) {
        stopAutoRefresh()
        
        canvasLog("[ProjectRefreshService] Starting auto-refresh (every \(Int(interval))s)")
        
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task {
                await self?.refresh()
            }
        }
        
        // Trigger immediate refresh
        Task {
            await refresh()
        }
    }
    
    /// Stop automatic refresh
    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }
    
    /// Manually trigger a refresh
    @discardableResult
    func refresh() async -> Result<Int, Error> {
        guard !isRefreshing else {
            canvasLog("[ProjectRefreshService] Refresh already in progress, skipping")
            return .failure(ProjectRefreshError.alreadyRefreshing)
        }
        
        isRefreshing = true
        defer { isRefreshing = false }
        
        canvasLog("[ProjectRefreshService] Starting manual refresh")
        
        do {
            // Scan filesystem
            let discovered = try await scanner.scanDevelopmentDirectory()
            canvasLog("[ProjectRefreshService] Discovered \(discovered.count) projects")
            
            // Update cache
            let updated = try cache.update(with: discovered)
            
            // Prune stale projects
            let pruned = try cache.prune()
            
            canvasLog("[ProjectRefreshService] Refresh complete: \(updated) updated, \(pruned) pruned")
            
            // Post notification for UI updates
            await MainActor.run {
                NotificationCenter.default.post(name: .projectCacheUpdated, object: nil)
            }
            
            return .success(updated)
        } catch {
            canvasLog("[ProjectRefreshService] Refresh failed: \(error)")
            return .failure(error)
        }
    }
    
    /// Get all cached projects (UI accessor)
    func getCachedProjects() async throws -> [CachedProject] {
        try await cache.getAll()
    }
    
    /// Get a specific project
    func getProject(at path: String) async throws -> CachedProject? {
        try await cache.get(path: path)
    }
    
    /// Load full context for a project
    func loadContext(for project: CachedProject) async -> ProjectContext {
        let loader = ProjectContextLoader()
        return await loader.loadContext(for: project)
    }
}

// MARK: - Errors

enum ProjectRefreshError: Error, LocalizedError {
    case alreadyRefreshing
    
    var errorDescription: String? {
        switch self {
        case .alreadyRefreshing:
            return "Project refresh already in progress"
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let projectCacheUpdated = Notification.Name("projectCacheUpdated")
}
