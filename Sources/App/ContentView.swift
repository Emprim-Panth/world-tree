import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState
    @State private var agentLabVM = AgentLabViewModel()

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
            Label("Central Brain", systemImage: "brain.head.profile")
                .tag(NavigationPanel.centralBrain)
            agentLabSidebarItem
            Divider()
            Label("Settings", systemImage: "gear")
                .tag(NavigationPanel.settings)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var agentLabSidebarItem: some View {
        HStack {
            Label("Agent Lab", systemImage: "theatermasks.fill")
            if agentLabVM.activeSession != nil {
                Spacer()
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
            }
        }
        .tag(NavigationPanel.agentLab)
    }

    // MARK: — Detail

    @ViewBuilder
    private var detailPanel: some View {
        switch appState.navigationPanel {
        case .commandCenter:
            CommandCenterView()
        case .tickets:
            AllTicketsView()
        case .brain:
            BrainEditorView()
        case .centralBrain:
            CentralBrainView()
        case .agentLab:
            AgentLabView()
        case .settings:
            SettingsView()
        }
    }
}
