import SwiftUI

/// Root view for iPad: NavigationSplitView with sidebar, content, and detail columns.
struct iPadRootView: View {
    @Environment(WorldTreeStore.self) private var store
    @Environment(ConnectionManager.self) private var connectionManager

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showNewTreeSheet = false
    @State private var showNewBranchSheet = false
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            TreeSidebarView(showNewTreeSheet: $showNewTreeSheet)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            BranchContentView(showNewBranchSheet: $showNewBranchSheet)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            ConversationDetailView()
        }
        .toolbar {
            // Sidebar toggle
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation {
                        columnVisibility = columnVisibility == .all ? .detailOnly : .all
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
            }

            // Connection status badge
            ToolbarItem(placement: .topBarLeading) {
                iPadConnectionStatusBadge()
            }

            // New tree — Cmd+N
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNewTreeSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            // Change server when stuck connecting
            if case .connecting = connectionManager.state {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Change Server") {
                        connectionManager.disconnect()
                        connectionManager.currentServer = nil
                    }
                }
            } else if case .reconnecting = connectionManager.state {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Change Server") {
                        connectionManager.disconnect()
                        connectionManager.currentServer = nil
                    }
                }
            }

            // Settings gear — Cmd+,
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                }
                .keyboardShortcut(",", modifiers: .command)
                .popover(isPresented: $showSettings) {
                    SettingsView()
                        .frame(minWidth: 320, minHeight: 400)
                }
            }
        }
        // New Tree sheet
        .sheet(isPresented: $showNewTreeSheet) {
            NewTreeSheet()
        }
        // New Branch sheet
        .sheet(isPresented: $showNewBranchSheet) {
            if let tree = store.currentTree {
                NewBranchSheet(treeId: tree.id)
            }
        }
        // Cmd+[ — clear branch (back to branch list)
        .overlay(alignment: .center) {
            Button("") { store.clearBranch() }
                .keyboardShortcut("[", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Connection Status Badge

private struct iPadConnectionStatusBadge: View {
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
        case .connected:                 return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected:              return .red
        }
    }

    private var statusLabel: String {
        switch connectionManager.state {
        case .connected:    return "Connected"
        case .connecting:   return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .disconnected: return "Disconnected"
        }
    }
}
