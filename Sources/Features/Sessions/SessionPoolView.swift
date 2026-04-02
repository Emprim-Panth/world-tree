import SwiftUI

/// Session Pool dashboard — replaces the old terminal-embedding SessionWorkspaceView.
/// Shows harness session rooms, their status, and provides a direct channel
/// to send messages into running sessions.
struct SessionPoolView: View {
    @State private var store = SessionPoolStore.shared
    @State private var selectedSession: PoolSession?
    @State private var messageText = ""
    @State private var sendingMessage = false

    var body: some View {
        VStack(spacing: 0) {
            poolHeader
            Divider()

            if !store.isHarnessRunning {
                harnessOfflineView
            } else if store.sessions.isEmpty {
                emptyPoolView
            } else {
                HSplitView {
                    sessionList
                        .frame(minWidth: 300)
                    sessionDetail
                        .frame(minWidth: 400)
                }
            }
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    // MARK: — Header

    private var poolHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Session Pool")
                    .font(.title2.bold())
                HStack(spacing: 12) {
                    poolBadge("\(store.ready) ready", color: .green)
                    poolBadge("\(store.busy) busy", color: .orange)
                    poolBadge("\(store.total)/\(store.maxSize) total", color: .secondary)
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

    private func poolBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: — Session List

    private var sessionList: some View {
        List(store.sessions, selection: $selectedSession) { session in
            sessionCard(session)
                .tag(session)
        }
        .listStyle(.inset)
    }

    private func sessionCard(_ session: PoolSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusIndicator(session.status)
                Text(session.id)
                    .font(.headline.monospaced())
                Spacer()
                Text(session.status.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(colorForStatus(session.status))
            }

            HStack {
                if let project = session.project {
                    Label(project, systemImage: "folder.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.accent)
                } else {
                    Label("idle", systemImage: "moon.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("tmux: \(session.tmuxName)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            if let busySince = session.busySince {
                let duration = timeSince(busySince)
                Text("Busy for \(duration)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: — Session Detail

    @ViewBuilder
    private var sessionDetail: some View {
        if let session = selectedSession {
            VStack(spacing: 0) {
                // Session info header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        statusIndicator(session.status)
                        Text("Session \(session.id)")
                            .font(.title3.bold())
                        Spacer()

                        Button("Open in Terminal") {
                            openInTerminal(session.tmuxName)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                    }

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text("tmux").foregroundStyle(.secondary).font(.caption)
                            Text(session.tmuxName).font(.caption.monospaced())
                        }
                        if let pid = session.pid {
                            GridRow {
                                Text("PID").foregroundStyle(.secondary).font(.caption)
                                Text("\(pid)").font(.caption.monospaced())
                            }
                        }
                        if let project = session.project {
                            GridRow {
                                Text("Project").foregroundStyle(.secondary).font(.caption)
                                Text(project).font(.caption)
                            }
                        }
                        if let taskId = session.taskId {
                            GridRow {
                                Text("Task").foregroundStyle(.secondary).font(.caption)
                                Text(taskId).font(.caption.monospaced())
                            }
                        }
                    }
                }
                .padding()

                Divider()

                // Direct channel
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Direct Channel")
                        .font(.headline)
                    Text("Send a message to this session's Claude instance")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("Type a message...", text: $messageText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { sendMessage(session) }

                        Button(action: { sendMessage(session) }) {
                            Image(systemName: "paperplane.fill")
                        }
                        .disabled(messageText.isEmpty || sendingMessage)
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                    }
                }
                .padding()
            }
        } else {
            VStack {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.quaternary)
                Text("Select a session")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: — Empty/Offline States

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
            Text("Or: launchctl bootstrap gui/$(id -u) ~/.cortana/harness/com.cortana.harness.plist")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyPoolView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("No sessions in pool")
                .font(.title3)
            Text("The harness will warm up sessions automatically")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: — Actions

    private func sendMessage(_ session: PoolSession) {
        guard !messageText.isEmpty else { return }
        let text = messageText
        messageText = ""
        sendingMessage = true

        Task {
            let success = await store.sendToSession(sessionId: session.id, text: text)
            sendingMessage = false
            if !success {
                wtLog("[SessionPool] Failed to send message to session \(session.id)")
            }
        }
    }

    private func openInTerminal(_ tmuxName: String) {
        // Launch Ghostty with tmux attach as the command — one click, you're in
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ghostty")
        task.arguments = ["-e", "/opt/homebrew/bin/tmux", "attach-session", "-t", tmuxName]
        do {
            try task.run()
        } catch {
            // Fallback: open Ghostty and let user attach manually
            if let ghosttyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
                NSWorkspace.shared.open(ghosttyURL)
            }
        }
    }

    // MARK: — Helpers

    private func statusIndicator(_ status: String) -> some View {
        Circle()
            .fill(colorForStatus(status))
            .frame(width: 10, height: 10)
    }

    private func colorForStatus(_ status: String) -> Color {
        switch status {
        case "ready": return Palette.success
        case "busy": return .orange
        case "warming": return Palette.accent
        case "dead": return Palette.error
        default: return Palette.neutral
        }
    }

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
