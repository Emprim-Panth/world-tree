import Foundation
import AppKit
import GRDB

/// Manages the lifecycle of all active dispatches with crash recovery.
///
/// Responsibilities:
/// - Track all running dispatch processes
/// - Recover interrupted dispatches on app launch
/// - Heartbeat to detect dead processes
/// - Graceful shutdown on app quit
@MainActor
final class DispatchSupervisor {
    static let shared = DispatchSupervisor()

    private var heartbeatTimer: Timer?
    private var terminationObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Startup

    /// Call on app launch to recover from previous crash and start monitoring.
    func start() {
        recoverInterruptedDispatches()
        startHeartbeat()
        registerForTermination()
    }

    // MARK: - Crash Recovery

    /// Find dispatches that were 'running' when the app died — mark them as interrupted.
    private func recoverInterruptedDispatches() {
        do {
            let count = try DatabaseManager.shared.write { db -> Int in
                try db.execute(sql: """
                    UPDATE canvas_dispatches
                    SET status = 'interrupted', completed_at = datetime('now')
                    WHERE status IN ('running', 'queued')
                    """)
                return db.changesCount
            }
            if count > 0 {
                wtLog("[DispatchSupervisor] Recovered \(count) interrupted dispatch(es) from previous session")
            }
        } catch {
            wtLog("[DispatchSupervisor] Failed to recover interrupted dispatches: \(error)")
        }
    }

    // MARK: - Heartbeat

    /// Every 30 seconds, verify the AgentSDKProvider's active processes are still alive.
    /// If a process died without updating the DB, mark its dispatch as failed.
    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkActiveDispatches()
            }
        }
    }

    private func checkActiveDispatches() {
        guard let provider = ProviderManager.shared.provider(withId: "agent-sdk") as? AgentSDKProvider else {
            return
        }

        let activeIds = Set(provider.activeDispatchIds)
        // Update AppState task count for UI badge
        AppState.shared.activeTaskCount = activeIds.count
        // Refresh heartbeat data alongside dispatch checks
        HeartbeatStore.shared.refresh()

        // Cross-reference DB: find dispatches marked 'running' that aren't tracked in memory
        do {
            let dbRunning = try DatabaseManager.shared.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM canvas_dispatches WHERE status = 'running'")
            }
            let orphaned = dbRunning.filter { !activeIds.contains($0) }
            if !orphaned.isEmpty {
                try DatabaseManager.shared.write { db in
                    for id in orphaned {
                        try db.execute(
                            sql: "UPDATE canvas_dispatches SET status = 'failed', error = 'Process lost (heartbeat)', completed_at = datetime('now') WHERE id = ?",
                            arguments: [id]
                        )
                    }
                }
                wtLog("[DispatchSupervisor] Marked \(orphaned.count) orphaned dispatch(es) as failed")
            }
        } catch {
            wtLog("[DispatchSupervisor] Heartbeat DB check failed: \(error)")
        }
    }

    // MARK: - Graceful Shutdown

    private func registerForTermination() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.gracefulShutdown()
            }
        }
    }

    private func gracefulShutdown() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        // The AgentSDKProvider's active processes will be terminated by the OS
        // when the app exits. On next launch, recoverInterruptedDispatches()
        // will mark any that were still 'running' as 'interrupted'.
        wtLog("[DispatchSupervisor] Graceful shutdown complete")
    }

    // MARK: - Prune

    /// Delete completed/failed dispatches older than 30 days.
    func pruneOldDispatches() {
        do {
            let count = try DatabaseManager.shared.write { db -> Int in
                try db.execute(sql: """
                    DELETE FROM canvas_dispatches
                    WHERE status IN ('completed', 'failed', 'interrupted', 'cancelled')
                    AND completed_at < datetime('now', '-30 days')
                    """)
                return db.changesCount
            }
            if count > 0 {
                wtLog("[DispatchSupervisor] Pruned \(count) old dispatch(es)")
            }
        } catch {
            wtLog("[DispatchSupervisor] Failed to prune: \(error)")
        }
    }
}
