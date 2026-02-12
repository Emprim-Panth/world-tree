import SwiftUI

/// Lists active daemon sessions with status indicators and kill controls.
struct AgentListView: View {
    @StateObject private var daemonService = DaemonService.shared

    /// When embedded in a container that provides its own header (e.g. sidebar DisclosureGroup),
    /// set to false to avoid a duplicate title.
    var showHeader: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                // Standalone header (when not embedded in sidebar)
                HStack {
                    Text("Active Sessions")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if !daemonService.activeSessions.isEmpty {
                        Text("\(daemonService.activeSessions.count)")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue)
                            .cornerRadius(8)
                    }

                    refreshButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()
            } else {
                // Minimal toolbar when embedded
                HStack {
                    Spacer()
                    refreshButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // Content
            if daemonService.activeSessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .onAppear {
            Task { await daemonService.refreshSessions() }
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await daemonService.refreshSessions() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .help("Refresh sessions")
    }

    // MARK: - Session List

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(daemonService.activeSessions) { session in
                    sessionRow(session)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func sessionRow(_ session: DaemonSession) -> some View {
        HStack(spacing: 10) {
            // Status indicator
            Circle()
                .fill(statusColor(for: session.status))
                .frame(width: 8, height: 8)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if let model = session.model {
                        Text(model)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .cornerRadius(3)
                    }
                }

                HStack(spacing: 8) {
                    Text(session.taskId)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospaced()
                        .lineLimit(1)

                    if let uptime = uptimeString(from: session.startedAt) {
                        Text(uptime)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Status label
            Text(session.status.capitalized)
                .font(.caption2)
                .foregroundStyle(statusColor(for: session.status))

            // Kill button
            Button {
                Task {
                    await daemonService.killSession(session.taskId)
                    await daemonService.refreshSessions()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Kill session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5))
        .cornerRadius(6)
        .padding(.horizontal, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No active sessions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Helpers

    private func statusColor(for status: String) -> Color {
        switch status.lowercased() {
        case "running", "active":
            return .green
        case "dispatching", "preparing":
            return .orange
        case "completing":
            return .blue
        case "failed", "error":
            return .red
        default:
            return .gray
        }
    }

    private func uptimeString(from startedAt: Date?) -> String? {
        guard let startedAt else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)

        if elapsed < 60 {
            return "\(Int(elapsed))s"
        } else if elapsed < 3600 {
            return "\(Int(elapsed / 60))m"
        } else {
            let hours = Int(elapsed / 3600)
            let minutes = Int((elapsed.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(minutes)m"
        }
    }
}
