import SwiftUI

/// Dispatcher dashboard — shows headless tasks, interactive sessions, and queue status.
struct SessionPoolView: View {
    @State private var store = SessionPoolStore.shared
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            dispatcherHeader
            Divider()

            if !store.isHarnessRunning {
                harnessOfflineView
            } else {
                Picker("", selection: $selectedTab) {
                    Text("Tasks (\(store.runningCount))").tag(0)
                    Text("Sessions (\(store.interactiveSessions.count))").tag(1)
                    Text("History (\(store.recentCompleted.count))").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                switch selectedTab {
                case 0: taskListView
                case 1: interactiveSessionsView
                case 2: completedListView
                default: EmptyView()
                }
            }
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    // MARK: — Header

    private var dispatcherHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dispatcher")
                    .font(.title2.bold())
                HStack(spacing: 12) {
                    statusBadge("\(store.runningCount) running", color: .orange)
                    if store.queuedCount > 0 {
                        statusBadge("\(store.queuedCount) queued", color: Palette.accent)
                    }
                    statusBadge("\(store.completedCount) done", color: Palette.success)
                    if store.failedCount > 0 {
                        statusBadge("\(store.failedCount) failed", color: Palette.error)
                    }
                }
            }

            Spacer()

            if store.isHarnessRunning {
                Circle()
                    .fill(Palette.success)
                    .frame(width: 8, height: 8)
                Text("Harness Running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(Palette.error)
                    .frame(width: 8, height: 8)
                Text("Harness Offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: — Running Tasks

    @ViewBuilder
    private var taskListView: some View {
        if store.runningTasks.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "bolt.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.quaternary)
                Text("No tasks running")
                    .font(.title3)
                Text("Dispatch tasks via socket, queue, or WorldTree")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(store.runningTasks) { task in
                taskRow(task)
            }
            .listStyle(.inset)
        }
    }

    private func taskRow(_ task: DispatcherTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(.orange)
                    .frame(width: 10, height: 10)
                Text(task.displayName)
                    .font(.headline.monospaced())
                Spacer()
                Text(task.model.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label(task.project, systemImage: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.accent)

                Spacer()

                if let pid = task.pid {
                    Text("PID \(pid)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            if let startedAt = task.startedAt {
                Text("Running for \(timeSince(startedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Cancel Task") {
                Task { await store.cancelTask(taskId: task.id) }
            }
        }
    }

    // MARK: — Interactive Sessions

    @ViewBuilder
    private var interactiveSessionsView: some View {
        if store.interactiveSessions.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "terminal")
                    .font(.system(size: 48))
                    .foregroundStyle(.quaternary)
                Text("No interactive sessions")
                    .font(.title3)
                Text("Request a session from a project card")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(store.interactiveSessions) { session in
                interactiveRow(session)
            }
            .listStyle(.inset)
        }
    }

    private func interactiveRow(_ session: InteractiveSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(Palette.success)
                    .frame(width: 10, height: 10)
                Text(session.id)
                    .font(.headline.monospaced())
                Spacer()
                Button("Open in Terminal") {
                    openInTerminal(session.tmuxName)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .controlSize(.small)
            }

            HStack {
                if let project = session.project {
                    Label(project, systemImage: "folder.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.accent)
                }

                Spacer()

                Text(session.model)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)

                Text("tmux: \(session.tmuxName)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: — Completed History

    @ViewBuilder
    private var completedListView: some View {
        if store.recentCompleted.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 48))
                    .foregroundStyle(.quaternary)
                Text("No recent tasks")
                    .font(.title3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(store.recentCompleted.reversed()) { task in
                completedRow(task)
            }
            .listStyle(.inset)
        }
    }

    private func completedRow(_ task: CompletedTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(task.isSuccess ? Palette.success : Palette.error)
                    .frame(width: 10, height: 10)
                Text(task.agent ?? "Direct")
                    .font(.headline.monospaced())
                Spacer()
                if let cost = task.costUsd {
                    Text("$\(cost, specifier: "%.4f")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(task.status.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(task.isSuccess ? Palette.success : Palette.error)
            }

            HStack {
                Label(task.project, systemImage: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if task.toolCount > 0 {
                    Text("\(task.toolCount) tools")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let exitCode = task.exitCode {
                    Text("exit \(exitCode)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: — Offline State

    private var harnessOfflineView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 48))
                .foregroundStyle(Palette.error)
            Text("Cortana Harness is offline")
                .font(.title3)
            Text("Start it with: cortana-harness")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: — Actions

    private func openInTerminal(_ tmuxName: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ghostty")
        task.arguments = ["-e", "/opt/homebrew/bin/tmux", "attach-session", "-t", tmuxName]
        do {
            try task.run()
        } catch {
            if let ghosttyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
                NSWorkspace.shared.open(ghosttyURL)
            }
        }
    }

    // MARK: — Helpers

    private func timeSince(_ isoString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: String(isoString.prefix(19))) else { return isoString }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
