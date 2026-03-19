import SwiftUI

/// Always-visible toolbar chip showing the live pipeline state.
/// Observes HeartbeatStore (refreshed every 30s by DispatchSupervisor).
/// Tapping navigates to the Factory Floor.
struct FactoryStatusChip: View {
    @ObservedObject private var store = HeartbeatStore.shared
    @Environment(AppState.self) var appState

    private var activeCount: Int {
        store.dispatchJobs.filter {
            $0.status == "running" || $0.status == "pending" || $0.status == "dispatched"
        }.count
    }

    var body: some View {
        Button {
            appState.selectedTreeId = nil
            appState.sidebarDestination = .factory
            appState.detailRefreshKey = UUID().uuidString
        } label: {
            HeartbeatIndicator(
                activeTaskCount: activeCount,
                lastHeartbeat: store.lastHeartbeat,
                signalCount: store.lastSignalCount
            )
        }
        .buttonStyle(.plain)
        .help(activeCount > 0
              ? "Factory Floor — \(activeCount) active task\(activeCount == 1 ? "" : "s")"
              : "Factory Floor — pipeline idle")
    }
}
