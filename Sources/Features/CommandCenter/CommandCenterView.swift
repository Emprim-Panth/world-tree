import SwiftUI

/// The bird's eye view of all concurrent work across projects.
/// Replaces DashboardView when no tree is selected.
struct CommandCenterView: View {
    @State private var viewModel = CommandCenterViewModel()
    @ObservedObject private var daemonService = DaemonService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                projectGrid
                activeWork
                recentCompletions
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .onAppear {
            viewModel.startObserving()
            daemonService.startMonitoring()
            daemonService.refreshTmuxSessions()
        }
        .onDisappear {
            viewModel.stopObserving()
            daemonService.stopMonitoring()
        }
        .sheet(isPresented: $viewModel.isShowingDispatchSheet) {
            DispatchSheet(projects: viewModel.projects) { message, project, model in
                viewModel.dispatch(message: message, project: project, model: model)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Command Center")
                    .font(.title2)
                    .fontWeight(.bold)

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

            // Refresh
            Button {
                viewModel.loadProjects()
                daemonService.refreshTmuxSessions()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
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
                        ProjectCardView(activity: activity)
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
            onCancel: { id in viewModel.cancelDispatch(id) }
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
                            recentRow(dispatch)
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
