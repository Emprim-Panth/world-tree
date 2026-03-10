import SwiftUI

struct ConversationView: View {
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(WorldTreeStore.self) private var store

    @State private var showNewTreeSheet = false
    @State private var showNewBranchSheet = false

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
                        if store.isLoadingBranches {
                            ProgressView("Loading…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            BranchesListView()
                        }
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
                refreshToolbarItem
                createToolbarItem
            }
            .sheet(isPresented: $showNewTreeSheet) {
                NewTreeSheet()
            }
            .sheet(isPresented: $showNewBranchSheet) {
                if let tree = store.currentTree {
                    NewBranchSheet(treeId: tree.id)
                }
            }
            .onChange(of: store.currentTree?.id) { _, newTreeId in
                guard let id = newTreeId, store.currentBranch == nil else { return }
                Task { await connectionManager.send(.listBranches(treeId: id)) }
            }
        }
    }

    private var navigationTitle: String {
        if let branch = store.currentBranch {
            return branch.displayName
        }
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
        // Only show when not fully connected — once connected, Settings handles server management
        if connectionManager.state != .connected {
            ToolbarItem(placement: .topBarLeading) {
                ConnectionStatusBadge()
            }
        }
    }

    @ToolbarContentBuilder
    private var backToolbarItem: some ToolbarContent {
        if store.currentBranch != nil {
            // In BranchView → back to BranchesListView
            ToolbarItem(placement: .topBarLeading) {
                Button(action: { store.clearBranch() }) {
                    Label("Branches", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
            }
        } else if store.currentTree != nil {
            // In BranchesListView → back to TreeListView
            ToolbarItem(placement: .topBarLeading) {
                Button(action: { store.clearTree() }) {
                    Label("Conversations", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var refreshToolbarItem: some ToolbarContent {
        if case .connected = connectionManager.state {
            if store.currentBranch == nil, store.currentTree == nil {
                // Tree list: refresh button (leading — frees trailing for + only)
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await connectionManager.send(.listTrees()) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            } else if store.currentTree != nil, store.currentBranch == nil {
                // Branch list: refresh button
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if let treeId = store.currentTree?.id {
                            Task { await connectionManager.send(.listBranches(treeId: treeId)) }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var createToolbarItem: some ToolbarContent {
        if case .connected = connectionManager.state {
            if store.currentBranch == nil, store.currentTree == nil {
                // Tree list: create new tree
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showNewTreeSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
            } else if store.currentTree != nil, store.currentBranch == nil {
                // Branch list: create new branch
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showNewBranchSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}

private struct ConnectionStatusBadge: View {
    @Environment(ConnectionManager.self) private var connectionManager

    var body: some View {
        Button(action: changeServer) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func changeServer() {
        connectionManager.suppressAutoConnect = true
        connectionManager.disconnect()
        connectionManager.currentServer = nil
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
        case .connected: return connectionManager.currentServer?.name ?? "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .disconnected: return "Disconnected"
        }
    }
}
