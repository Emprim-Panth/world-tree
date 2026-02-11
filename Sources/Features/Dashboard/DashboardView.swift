import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var daemonService = DaemonService.shared
    @State private var recentTrees: [ConversationTree] = []
    @State private var treeCount: Int = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Hero
                VStack(spacing: 8) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.cyan)

                    Text("Cortana Canvas")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Tree-structured conversations with branching timelines")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                // Status cards
                HStack(spacing: 16) {
                    statusCard(
                        icon: "bubble.left.and.bubble.right",
                        title: "Trees",
                        value: "\(treeCount)",
                        color: .blue
                    )

                    statusCard(
                        icon: daemonService.isConnected ? "checkmark.circle" : "xmark.circle",
                        title: "Daemon",
                        value: daemonService.isConnected ? "Connected" : "Offline",
                        color: daemonService.isConnected ? .green : .red
                    )
                }
                .frame(maxWidth: 500)

                // Quick actions
                HStack(spacing: 12) {
                    Button {
                        NotificationCenter.default.post(name: .createNewTree, object: nil)
                    } label: {
                        Label("New Tree", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        loadData()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                // Recent trees
                if !recentTrees.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recent")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(recentTrees) { tree in
                            recentTreeRow(tree)
                        }
                    }
                    .frame(maxWidth: 600)
                }

                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            loadData()
            daemonService.startMonitoring()
        }
    }

    private func loadData() {
        do {
            recentTrees = try TreeStore.shared.listTrees()
            treeCount = recentTrees.count
            recentTrees = Array(recentTrees.prefix(10))
        } catch {
            // Silent — dashboard is informational
        }
    }

    private func statusCard(icon: String, title: String, value: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.quaternary)
        .cornerRadius(12)
    }

    private func recentTreeRow(_ tree: ConversationTree) -> some View {
        Button {
            appState.selectedTreeId = tree.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tree.name)
                        .fontWeight(.medium)
                    HStack(spacing: 8) {
                        if let project = tree.project {
                            Text(project)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(tree.branches.count) branches")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Text(tree.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5))
            .cornerRadius(8)
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }
}
