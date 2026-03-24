import SwiftUI

struct CommandCenterView: View {
    @Environment(AppState.self) var appState
    @State private var viewModel = CommandCenterViewModel()
    @ObservedObject private var heartbeatStore = HeartbeatStore.shared
    @ObservedObject private var activityStore = DispatchActivityStore.shared
    @State private var ccTab: CCTab = .overview
    @State private var isShowingDispatchSheet = false

    private enum CCTab: String, CaseIterable {
        case overview = "Overview"
        case activity = "Activity"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                tabPicker

                if ccTab == .activity {
                    DispatchActivityView()
                        .padding(.top, 4)
                } else {
                    if !viewModel.pendingHandoffs.isEmpty {
                        HandoffBanner(
                            handoffs: viewModel.pendingHandoffs,
                            onDismiss: { viewModel.dismissHandoff($0) },
                            onPickUp: { viewModel.pickUpHandoff($0) }
                        )
                    }
                    projectGrid
                    activeDispatches
                    recentCompletions
                }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .onAppear {
            viewModel.startObserving()
            viewModel.refreshHandoffs()
            Task { await heartbeatStore.refreshAsync() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await heartbeatStore.refreshAsync()
            }
        }
        .onDisappear {
            viewModel.stopObserving()
        }
        .sheet(isPresented: $isShowingDispatchSheet) {
            DispatchSheet(projects: viewModel.compassProjects.map(\.project)) { message, project, model in
                // Dispatch via gateway
                Task {
                    guard let gateway = GatewayClient.fromLocalConfig() else { return }
                    _ = try? await gateway.createHandoff(
                        message: "\(message)\n\n[model: \(model ?? "claude-sonnet-4-6")]",
                        project: project
                    )
                }
            }
        }
    }

    // MARK: — Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("Command Center")
                        .font(.title2.bold())
                    HeartbeatIndicator(
                        activeTaskCount: heartbeatStore.activeDispatches,
                        lastHeartbeat: heartbeatStore.lastHeartbeat,
                        signalCount: heartbeatStore.lastSignalCount
                    )
                }
                HStack(spacing: 12) {
                    statusPill("bolt.fill",
                               "\(viewModel.activeDispatches.count) active",
                               viewModel.activeDispatches.isEmpty ? .gray : .green)
                    statusPill("folder",
                               "\(viewModel.compassProjects.count) projects",
                               .secondary)
                }
            }
            Spacer()
            Button { viewModel.refreshProjects(); viewModel.refreshHandoffs() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("r", modifiers: .command)

            Button { isShowingDispatchSheet = true } label: {
                Label("Dispatch", systemImage: "paperplane.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func statusPill(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
    }

    // MARK: — Tab Picker

    private var tabPicker: some View {
        HStack {
            Picker("", selection: $ccTab) {
                ForEach(CCTab.allCases, id: \.self) { tab in
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                        if tab == .activity, activityStore.totalUnread > 0 {
                            Text("\(activityStore.totalUnread)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.cyan.opacity(0.85))
                                .clipShape(Capsule())
                        }
                    }
                    .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            Spacer()
        }
        .onChange(of: ccTab) { _, tab in
            if tab == .activity {
                for project in activityStore.unreadCounts.keys
                    where (activityStore.unreadCounts[project] ?? 0) > 0 {
                    activityStore.markRead(project)
                }
            }
        }
    }

    // MARK: — Project Grid

    private var projectGrid: some View {
        Group {
            if viewModel.compassProjects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark").font(.title2).foregroundStyle(.tertiary)
                    Text("No projects found").font(.caption).foregroundStyle(.secondary)
                    Text("compass.db not initialized or no projects tracked")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(viewModel.compassProjects, id: \.project) { state in
                        CompassProjectCard(
                            compassState: state,
                            ticketCount: TicketStore.shared.openCount(for: state.project),
                            blockedCount: TicketStore.shared.blockedCount(for: state.project)
                        )
                    }
                }
            }
        }
    }

    // MARK: — Active Dispatches

    private var activeDispatches: some View {
        Group {
            if !viewModel.activeDispatches.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("bolt.fill", "RUNNING", .green)
                    ForEach(viewModel.activeDispatches) { dispatch in
                        dispatchRow(dispatch, isActive: true)
                    }
                }
            }
        }
    }

    // MARK: — Recent Completions

    private var recentCompletions: some View {
        Group {
            if !viewModel.recentDispatches.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("clock.arrow.circlepath", "RECENT", .secondary)
                    ForEach(viewModel.recentDispatches.prefix(10)) { dispatch in
                        dispatchRow(dispatch, isActive: false)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ icon: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func dispatchRow(_ dispatch: WorldTreeDispatch, isActive: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "circle.fill" :
                    (dispatch.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill"))
                .font(.system(size: 10))
                .foregroundStyle(isActive ? .green :
                    (dispatch.status == .completed ? .green : .red))

            Text(dispatch.project)
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)

            Text(dispatch.displayMessage)
                .font(.system(size: 10)).foregroundStyle(.primary.opacity(0.7))
                .lineLimit(1).truncationMode(.tail)

            Spacer()

            if let completed = dispatch.completedAt {
                Text(completed, style: .relative)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.quaternary.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: — Handoff Banner

struct HandoffBanner: View {
    let handoffs: [Handoff]
    let onDismiss: (String) -> Void
    let onPickUp: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill").font(.system(size: 10)).foregroundStyle(.orange)
                Text("PENDING HANDOFFS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                Spacer()
                Text("\(handoffs.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
            }
            ForEach(handoffs) { handoff in
                HStack(spacing: 8) {
                    Text(handoff.message).font(.system(size: 12)).lineLimit(2)
                    Spacer()
                    Button("Pick Up") { onPickUp(handoff.id) }
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(.orange)
                    Button { onDismiss(handoff.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.2)) }
    }
}
