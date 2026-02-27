import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) var appState
    @StateObject private var daemonService = DaemonService.shared
    @State private var recentTrees: [ConversationTree] = []
    @State private var treeCount: Int = 0
    @State private var sessionStates: [SessionStateStore.SessionState] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Hero
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 80, height: 80)

                    Text("World Tree")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Tree-structured conversations with branching timelines")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                // Status cards
                HStack(spacing: 16) {
                    statusCard(
                        icon: daemonService.isConnected ? "checkmark.circle" : "xmark.circle",
                        title: "Daemon",
                        value: daemonService.isConnected ? "Connected" : "Offline",
                        color: daemonService.isConnected ? .green : .red
                    )

                    statusCard(
                        icon: "bubble.left.and.bubble.right",
                        title: "Trees",
                        value: "\(treeCount)",
                        color: .blue
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

                // Session Intelligence
                if !sessionStates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Session Intelligence")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(sessionStates, id: \.sessionId) { state in
                            sessionStateCard(state)
                        }
                    }
                    .frame(maxWidth: 600)
                }

                // Recent trees (or first-run empty state)
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
                } else {
                    VStack(spacing: 8) {
                        Text("No conversations yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Create a tree to start branching conversations with \(LocalAgentIdentity.name).")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: 400)
                }

                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            loadData()
            daemonService.startMonitoring()
        }
        .onDisappear {
            daemonService.stopMonitoring()
        }
    }

    private func loadData() {
        do {
            recentTrees = try TreeStore.shared.listTrees()
            treeCount = recentTrees.count
            recentTrees = Array(recentTrees.prefix(10))
        } catch {
            wtLog("[Dashboard] Failed to load trees: \(error)")
        }
        sessionStates = SessionStateStore.shared.getActiveStates()
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }

    private func sessionStateCard(_ state: SessionStateStore.SessionState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: project + phase
            HStack(spacing: 6) {
                Image(systemName: state.phaseIcon)
                    .foregroundStyle(.blue)
                    .font(.caption)
                if let project = state.project, !project.isEmpty {
                    Text(project)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                Text(state.phaseLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.12))
                    .cornerRadius(4)
                Spacer()
                Text(state.lastUpdated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Goal
            if let goal = state.goal, !goal.isEmpty {
                Text(goal)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            // Blockers + errors
            HStack(spacing: 8) {
                if !state.blockers.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                        Text("\(state.blockers.count) blocker\(state.blockers.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                if state.errorCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text("\(state.errorCount) error\(state.errorCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5))
        .cornerRadius(8)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
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
                        if let project = tree.project, !project.isEmpty {
                            Text(project)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if tree.messageCount > 0 {
                            Text("\(tree.messageCount) messages")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
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
        }
        .buttonStyle(.plain)
    }
}
