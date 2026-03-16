import SwiftUI

/// The bird's eye view of all concurrent work across projects.
/// Replaces DashboardView when no tree is selected.
struct CommandCenterView: View {
    @State private var viewModel = CommandCenterViewModel()
    @ObservedObject private var daemonService = DaemonService.shared
    @ObservedObject private var heartbeatStore = HeartbeatStore.shared
    private var outputStore = JobOutputStreamStore.shared
    @State private var isShowingRoster = false
    @State private var isShowingEventRules = false
    @ObservedObject private var attentionStore = AttentionStore.shared
    @ObservedObject private var conflictDetector = ConflictDetector.shared
    @ObservedObject private var cortanaOpsStore = CortanaOpsStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                if !attentionStore.unacknowledged.isEmpty {
                    AttentionPanel()
                }
                // Pending handoffs from gateway
                if !viewModel.pendingHandoffs.isEmpty {
                    HandoffBanner(
                        handoffs: viewModel.pendingHandoffs,
                        onDismiss: { id in viewModel.dismissHandoff(id) },
                        onPickUp: { id in viewModel.pickUpHandoff(id) }
                    )
                }
                CortanaOpsSection()
                CoordinatorSection()
                ForEach(conflictDetector.activeConflicts, id: \.filePath) { conflict in
                    ConflictWarningBanner(conflict: conflict)
                }
                DecisionReviewSection()
                AgentStatusBoard()
                TokenDashboardView()
                LiveStreamsSection()
                projectGrid
                StarfleetActivitySection()
                if UserDefaults.standard.bool(forKey: "pencil.feature.enabled") {
                    PencilDesignSection()
                }
                activeWork
                recentCompletions
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .onAppear {
            viewModel.startObserving()
            viewModel.refreshHandoffs()
            daemonService.refreshTmuxSessions()
            AgentStatusStore.shared.startObserving()
            cortanaOpsStore.start()
            EventRuleStore.shared.loadRules()
            UIStateStore.shared.loadAll()
            Task { await heartbeatStore.refreshAsync() }
        }
        .task {
            // Refresh heartbeat every 30s while Command Center is visible
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await heartbeatStore.refreshAsync()
            }
        }
        .onDisappear {
            viewModel.stopObserving()
            AgentStatusStore.shared.stopObserving()
            cortanaOpsStore.stop()
        }
        .sheet(isPresented: $viewModel.isShowingDispatchSheet) {
            DispatchSheet(projects: viewModel.projects) { message, project, model, template in
                viewModel.dispatch(message: message, project: project, model: model, template: template)
            }
        }
        .sheet(isPresented: $isShowingRoster) {
            StarfleetRosterView()
                .frame(width: 700, height: 500)
        }
        .sheet(isPresented: $isShowingEventRules) {
            EventRulesSheet()
        }
        .sheet(item: Binding(
            get: { outputStore.inspectedEntry },
            set: { _ in outputStore.dismissInspector() }
        )) { entry in
            JobOutputInspectorView(entry: entry) {
                outputStore.dismissInspector()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Text("Command Center")
                        .font(.title2)
                        .fontWeight(.bold)

                    HeartbeatIndicator(
                        activeTaskCount: heartbeatStore.activeDispatches,
                        lastHeartbeat: heartbeatStore.lastHeartbeat,
                        signalCount: heartbeatStore.lastSignalCount
                    )
                }

                HStack(spacing: 12) {
                    statusPill(
                        icon: "bolt.fill",
                        text: "\(viewModel.activeDispatches.count + viewModel.activeJobs.count) active",
                        color: viewModel.activeDispatches.isEmpty && viewModel.activeJobs.isEmpty ? .gray : .green
                    )

                    statusPill(
                        icon: "terminal",
                        text: "\(daemonService.tmuxSessions.filter(\.isClaudeSession).count) sessions",
                        color: daemonService.tmuxSessions.contains(where: \.isClaudeSession) ? .cyan : .gray
                    )

                    statusPill(
                        icon: "folder",
                        text: "\(viewModel.projects.count) projects",
                        color: .secondary
                    )
                }
            }

            Spacer()

            // Event Rules button
            Button {
                isShowingEventRules = true
            } label: {
                Label("Rules", systemImage: "bolt.trianglebadge.exclamationmark")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Opens event trigger rules for automation")

            // Crew Roster button
            Button {
                isShowingRoster = true
            } label: {
                Label("Crew", systemImage: "person.3.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Opens Starfleet crew roster for agent dispatch")

            // Dispatch button
            Button {
                viewModel.loadProjects() // refresh before showing sheet
                guard !viewModel.projects.isEmpty else { return }
                viewModel.isShowingDispatchSheet = true
            } label: {
                Label("Dispatch", systemImage: "paperplane.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Opens dispatch sheet to send work to agents")

            // Refresh
            Button {
                viewModel.loadProjects()
                viewModel.refreshCompassAndTickets()
                daemonService.refreshTmuxSessions()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Refresh projects")
        }
    }

    private func statusPill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Project Grid

    private var projectGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.projectActivities.isEmpty {
                let columns = [
                    GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 8)
                ]

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(viewModel.projectActivities) { activity in
                        CompassProjectCard(
                            activity: activity,
                            compassState: viewModel.compassStates[activity.project.name],
                            ticketCount: viewModel.ticketCounts[activity.project.name] ?? 0,
                            blockedCount: viewModel.blockedCounts[activity.project.name] ?? 0
                        )
                    }
                }
            } else if viewModel.projects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No projects found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Projects are scanned from ~/Development")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    // MARK: - Active Work

    private var activeWork: some View {
        ActiveWorkSection(
            dispatches: viewModel.activeDispatches,
            jobs: viewModel.activeJobs,
            onCancel: { id in viewModel.cancelDispatch(id) },
            onInspectDispatch: { id in outputStore.inspect(id: id, kind: .dispatch) },
            onInspectJob: { id in outputStore.inspect(id: id, kind: .job) }
        )
    }

    // MARK: - Recent Completions

    private var recentCompletions: some View {
        Group {
            if !viewModel.recentDispatches.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("RECENT")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    VStack(spacing: 4) {
                        ForEach(viewModel.recentDispatches.prefix(10)) { dispatch in
                            Button {
                                outputStore.inspect(id: dispatch.id, kind: .dispatch)
                            } label: {
                                recentRow(dispatch)
                            }
                            .buttonStyle(.plain)
                            .help("View dispatch output")
                        }
                    }
                }
            }
        }
    }

    private func recentRow(_ dispatch: WorldTreeDispatch) -> some View {
        HStack(spacing: 8) {
            Image(systemName: dispatch.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(dispatch.status == .completed ? .green : .red)
                .accessibilityLabel(dispatch.status == .completed ? "Completed" : "Failed")

            Text(dispatch.project)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Text(dispatch.displayMessage)
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Token usage
            if let tokensIn = dispatch.resultTokensIn, let tokensOut = dispatch.resultTokensOut,
               tokensIn + tokensOut > 0 {
                Text(formatTokens(tokensIn + tokensOut))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // Duration
            if let dur = dispatch.durationString {
                Text(dur)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // Completion time
            if let completed = dispatch.completedAt {
                Text(completed, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(count / 1_000_000)M" }
        if count >= 1000 { return "\(count / 1000)K" }
        return "\(count)"
    }
}

// MARK: - Handoff Banner

/// Shows pending handoffs from the Ark Gateway — cross-device work items
/// that need attention (e.g., Telegram handoffs, daemon-created tasks).
struct HandoffBanner: View {
    let handoffs: [Handoff]
    let onDismiss: (String) -> Void
    let onPickUp: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("PENDING HANDOFFS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Text("\(handoffs.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
            }

            ForEach(handoffs) { handoff in
                HandoffRow(handoff: handoff, onDismiss: onDismiss, onPickUp: onPickUp)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.2), lineWidth: 1)
        }
    }
}

private struct HandoffRow: View {
    let handoff: Handoff
    let onDismiss: (String) -> Void
    let onPickUp: (String) -> Void

    private var priorityColor: Color {
        switch handoff.priority {
        case "high", "critical": return .red
        case "normal": return .orange
        default: return .secondary
        }
    }

    private var timeAgo: String {
        let seconds = Int(Date().timeIntervalSince1970) - Int(handoff.createdAt)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    var body: some View {
        HStack(spacing: 10) {
            // Priority indicator
            Circle()
                .fill(priorityColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(handoff.message)
                    .font(.system(size: 12))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let project = handoff.project {
                        Text(project)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if let source = handoff.source {
                        Text("via \(source)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Text(timeAgo)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button {
                onPickUp(handoff.id)
            } label: {
                Text("Pick Up")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)

            Button {
                onDismiss(handoff.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss handoff")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
