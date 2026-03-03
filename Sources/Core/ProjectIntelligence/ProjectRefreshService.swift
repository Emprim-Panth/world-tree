import Foundation

/// Service that periodically scans projects and updates cache
/// Runs in background, can be triggered manually
@MainActor
final class ProjectRefreshService {
    static let shared = ProjectRefreshService()

    private let scanner = ProjectScanner()
    private let cache = ProjectCache()
    private var timerSource: DispatchSourceTimer?
    private var isRefreshing = false
    private var pendingRefresh = false
    private var lastRefreshCompleted: Date?
    /// Minimum interval between refreshes to prevent cascade during reconnect storms.
    private static let minRefreshInterval: TimeInterval = 30

    private init() {}

    /// Start automatic refresh (every 5 minutes)
    func startAutoRefresh(interval: TimeInterval = 300) {
        stopAutoRefresh()

        wtLog("[ProjectRefreshService] Starting auto-refresh (every \(Int(interval))s)")

        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        source.resume()
        timerSource = source

        // Trigger immediate refresh
        Task {
            await refresh()
        }
    }

    /// Stop automatic refresh
    func stopAutoRefresh() {
        timerSource?.cancel()
        timerSource = nil
    }

    /// Manually trigger a refresh
    @discardableResult
    func refresh() async -> Result<Int, Error> {
        // Throttle: skip if last refresh completed within minRefreshInterval
        if let last = lastRefreshCompleted,
           Date().timeIntervalSince(last) < Self.minRefreshInterval {
            return .failure(ProjectRefreshError.throttled)
        }

        guard !isRefreshing else {
            wtLog("[ProjectRefreshService] Refresh already in progress, queuing pending refresh")
            pendingRefresh = true
            return .failure(ProjectRefreshError.alreadyRefreshing)
        }

        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshCompleted = Date()
            if pendingRefresh {
                pendingRefresh = false
                Task { [weak self] in
                    await self?.refresh()
                }
            }
        }

        wtLog("[ProjectRefreshService] Starting manual refresh")

        do {
            // Scan filesystem OFF MainActor — git subprocesses block with semaphores
            let scanner = self.scanner
            let discovered = try await Task.detached(priority: .utility) {
                try await scanner.scanDevelopmentDirectory()
            }.value
            wtLog("[ProjectRefreshService] Discovered \(discovered.count) projects")

            // Update cache
            let updated = try cache.update(with: discovered)

            // Prune stale projects
            let pruned = try cache.prune()

            wtLog("[ProjectRefreshService] Refresh complete: \(updated) updated, \(pruned) pruned")

            // Post notification for UI updates (already on @MainActor)
            NotificationCenter.default.post(name: .projectCacheUpdated, object: nil)

            return .success(updated)
        } catch {
            wtLog("[ProjectRefreshService] Refresh failed: \(error)")
            return .failure(error)
        }
    }
    
    /// Get all cached projects (UI accessor)
    func getCachedProjects() async throws -> [CachedProject] {
        try cache.getAll()
    }
    
    /// Get a specific project
    func getProject(at path: String) async throws -> CachedProject? {
        try cache.get(path: path)
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
    case throttled

    var errorDescription: String? {
        switch self {
        case .alreadyRefreshing:
            return "Project refresh already in progress"
        case .throttled:
            return "Project refresh throttled — too soon since last refresh"
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let projectCacheUpdated = Notification.Name("projectCacheUpdated")
}
