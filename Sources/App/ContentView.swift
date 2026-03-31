import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        NavigationSplitView {
            navSidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detailPanel
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("World Tree")
        .frame(minWidth: 900, minHeight: 600)
    }

    // MARK: — Sidebar

    @ViewBuilder
    private var navSidebar: some View {
        @Bindable var state = appState
        List(selection: $state.navigationPanel) {
            Label("Command Center", systemImage: "house.fill")
                .tag(NavigationPanel.commandCenter)
            Label("Tickets", systemImage: "checklist")
                .tag(NavigationPanel.tickets)
            Label("Brain", systemImage: "brain")
                .tag(NavigationPanel.brain)
            Label("Starfleet", systemImage: "person.2.badge.gearshape")
                .tag(NavigationPanel.starfleet)
            Label("Sessions", systemImage: "terminal.fill")
                .tag(NavigationPanel.sessions)
            Divider()
            Label("Settings", systemImage: "gear")
                .tag(NavigationPanel.settings)
        }
        .listStyle(.sidebar)
    }

    // MARK: — Detail

    /// Sessions view is kept alive in a ZStack so PTY processes survive tab switches.
    /// Other panels are created/destroyed normally (they're stateless dashboards).
    @ViewBuilder
    private var detailPanel: some View {
        ZStack {
            // Sessions layer — always in the hierarchy, hidden when not selected
            SessionWorkspaceView()
                .opacity(appState.navigationPanel == .sessions ? 1 : 0)
                .allowsHitTesting(appState.navigationPanel == .sessions)

            // Other panels — only created when selected
            if appState.navigationPanel != .sessions {
                switch appState.navigationPanel {
                case .commandCenter:
                    CommandCenterView()
                case .tickets:
                    AllTicketsView()
                case .brain:
                    UnifiedBrainView()
                case .starfleet:
                    StarfleetCommandView()
                case .settings:
                    SettingsView()
                case .sessions:
                    EmptyView() // handled above
                }
            }
        }
    }
}
