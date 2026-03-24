import Foundation
import GRDB

/// Tracks autonomous dispatch completions across projects.
/// Maintains per-project "unread" state — a project is "ready" when a dispatch
/// completed for it while it wasn't the currently selected project.
/// Clears when the user enters that project.
@MainActor
final class DispatchActivityStore: ObservableObject {
    static let shared = DispatchActivityStore()

    /// All recent completions, newest first — drives the Activity tab.
    @Published private(set) var recentCompletions: [WorldTreeDispatch] = []

    /// project name (lowercased) → count of unread autonomous completions.
    @Published private(set) var unreadCounts: [String: Int] = [:]

    private var observationTask: Task<Void, Never>?
    private let seenKey = "DispatchActivityStore.lastSeen"

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            guard let dbPool = DatabaseManager.shared.dbPool else { return }

            let observation = ValueObservation.trackingConstantRegion { db -> [WorldTreeDispatch] in
                try WorldTreeDispatch
                    .filter(Column("status") == "completed" || Column("status") == "failed")
                    .order(Column("completed_at").desc)
                    .limit(100)
                    .fetchAll(db)
            }

            do {
                for try await dispatches in observation.values(in: dbPool) {
                    self?.recentCompletions = dispatches
                    self?.rebuildUnreadCounts(from: dispatches)
                }
            } catch {}
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Unread State

    /// Mark all completions for a project as read.
    /// Called when the user selects a project in the sidebar or enters a conversation in it.
    func markRead(_ projectName: String) {
        let key = projectName.lowercased()
        guard (unreadCounts[key] ?? 0) > 0 else { return }
        unreadCounts[key] = 0

        var seen = savedLastSeenDates()
        seen[key] = Date()
        UserDefaults.standard.set(
            seen.mapValues { $0.timeIntervalSince1970 },
            forKey: seenKey
        )
    }

    func unreadCount(for projectName: String) -> Int {
        unreadCounts[projectName.lowercased()] ?? 0
    }

    var totalUnread: Int {
        unreadCounts.values.reduce(0, +)
    }

    // MARK: - Private

    private func rebuildUnreadCounts(from dispatches: [WorldTreeDispatch]) {
        let seen = savedLastSeenDates()
        let selected = currentlySelectedProjectName()
        var counts: [String: Int] = [:]

        for dispatch in dispatches {
            guard dispatch.status == .completed, let completedAt = dispatch.completedAt else { continue }
            let key = dispatch.project.lowercased()
            // Don't badge the project you're currently looking at
            if let sel = selected, key == sel.lowercased() { continue }
            let lastSeen = seen[key] ?? .distantPast
            if completedAt > lastSeen {
                counts[key, default: 0] += 1
            }
        }

        unreadCounts = counts
    }

    private func savedLastSeenDates() -> [String: Date] {
        guard let raw = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Double] else { return [:] }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func currentlySelectedProjectName() -> String? {
        return AppState.shared.selectedProject
    }
}
