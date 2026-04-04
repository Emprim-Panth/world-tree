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
            Label("The Forge", systemImage: "hammer.fill")
                .tag(NavigationPanel.forge)
            Label("Scratchpad", systemImage: "note.text")
                .tag(NavigationPanel.scratchpad)
            Label("Brain", systemImage: "brain")
                .tag(NavigationPanel.brain)
            Label("Starfleet", systemImage: "person.2.badge.gearshape")
                .tag(NavigationPanel.starfleet)
            Label("Session Pool", systemImage: "square.stack.3d.up")
                .tag(NavigationPanel.sessions)
            Divider()
            Label("Settings", systemImage: "gear")
                .tag(NavigationPanel.settings)
        }
        .listStyle(.sidebar)
    }

    // MARK: — Detail

    @ViewBuilder
    private var detailPanel: some View {
        switch appState.navigationPanel {
        case .commandCenter:
            CommandCenterView()
        case .tickets:
            AllTicketsView()
        case .forge:
            ForgeView()
        case .scratchpad:
            ScratchpadView()
        case .brain:
            UnifiedBrainView()
        case .starfleet:
            StarfleetCommandView()
        case .sessions:
            SessionPoolView()
        case .settings:
            SettingsView()
        }
    }
}
