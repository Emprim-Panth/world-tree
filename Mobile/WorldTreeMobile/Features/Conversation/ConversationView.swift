import SwiftUI

struct ConversationView: View {
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(WorldTreeStore.self) private var store

    @State private var showNewTreeSheet = false

    var body: some View {
        NavigationStack {
            Group {
                switch connectionManager.state {
                case .disconnected:
                    disconnectedView
                case .connecting, .reconnecting:
                    connectingView
                case .connected:
                    if store.currentBranch != nil {
                        BranchView()
                    } else if store.currentTree != nil {
                        // Branches are loading; auto-select will switch to BranchView shortly.
                        ProgressView("Loading…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TreeListView()
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                connectionStatusToolbarItem
                backToolbarItem
                createToolbarItem
            }
            .sheet(isPresented: $showNewTreeSheet) {
                NewTreeSheet()
            }
            .onChange(of: store.currentTree?.id) { _, newTreeId in
                guard let id = newTreeId, store.currentBranch == nil else { return }
                Task { await connectionManager.send(.listBranches(treeId: id)) }
            }
        }
    }

    private var navigationTitle: String {
        if let tree = store.currentTree {
            return tree.name
        }
        return connectionManager.currentServer?.name ?? "World Tree"
    }

    private var disconnectedView: some View {
        ContentUnavailableView(
            "Disconnected",
            systemImage: "wifi.slash",
            description: Text("Tap Reconnect or check your server settings.")
        )
    }

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(connectingLabel)
                .foregroundStyle(.secondary)
            Button("Change Server") {
                connectionManager.suppressAutoConnect = true
                connectionManager.disconnect()
                connectionManager.currentServer = nil
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
    }

    private var connectingLabel: String {
        if case .reconnecting(let attempt) = connectionManager.state {
            return "Reconnecting (attempt \(attempt) of \(Constants.Network.reconnectMaxAttempts))..."
        }
        return "Connecting..."
    }

    @ToolbarContentBuilder
    private var connectionStatusToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            ConnectionStatusBadge()
        }
    }

    @ToolbarContentBuilder
    private var backToolbarItem: some ToolbarContent {
        if store.currentBranch != nil || store.currentTree != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { store.clearTree() }) {
                    Label("Projects", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var createToolbarItem: some ToolbarContent {
        if case .connected = connectionManager.state, store.currentBranch == nil, store.currentTree == nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showNewTreeSheet = true }) {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

private struct ConnectionStatusBadge: View {
    @Environment(ConnectionManager.self) private var connectionManager

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch connectionManager.state {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return .red
        }
    }

    private var statusLabel: String {
        switch connectionManager.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .disconnected: return "Disconnected"
        }
    }
}
