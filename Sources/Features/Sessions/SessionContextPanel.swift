import SwiftUI

/// Right-side context panel showing project state alongside the terminal.
struct SessionContextPanel: View {
    let session: SessionManager.ManagedSession
    var compassStore = CompassStore.shared
    var ticketStore = TicketStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                projectCard
                LiveDiffView(projectPath: session.projectPath)
                activeTickets
                sessionInfo
            }
            .padding(12)
        }
        .background(Palette.cardBackground.opacity(0.3))
    }

    private var projectCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Palette.cortana)
                Text(session.project)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            if let state = compassStore.states[session.project] {
                if let goal = state.currentGoal {
                    HStack(spacing: 4) {
                        Image(systemName: "target").font(.system(size: 9))
                        Text(goal).font(.system(size: 10)).lineLimit(2)
                    }
                    .foregroundStyle(.secondary)
                }
                if let phase = state.currentPhase {
                    HStack(spacing: 4) {
                        Circle().fill(Palette.forPhase(phase)).frame(width: 6, height: 6)
                        Text(phase.capitalized).font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                }
                if !state.blockers.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundStyle(Palette.blocked)
                        Text("\(state.blockers.count) blocker(s)")
                            .font(.system(size: 10)).foregroundStyle(Palette.blocked)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.cardBackground))
    }

    private var activeTickets: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checklist")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Tickets")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(ticketStore.openCount(for: session.project))")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }

            ForEach(ticketStore.tickets(for: session.project).prefix(5)) { ticket in
                HStack(spacing: 4) {
                    Image(systemName: ticket.statusIcon)
                        .font(.system(size: 8))
                        .foregroundStyle(Palette.forStatus(ticket.status))
                    Text(ticket.title)
                        .font(.system(size: 9))
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.cardBackground))
    }

    private var sessionInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Session")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }

            Group {
                HStack(spacing: 4) {
                    Text("Status:").foregroundStyle(.tertiary)
                    Text(session.state.rawValue.capitalized)
                        .foregroundStyle(session.state == .running ? Palette.success : Palette.neutral)
                }
                HStack(spacing: 4) {
                    Text("Started:").foregroundStyle(.tertiary)
                    Text(session.createdAt, style: .relative)
                }
                HStack(spacing: 4) {
                    Text("Permissions:").foregroundStyle(.tertiary)
                    Text(session.skipPermissions ? "Bypassed" : "Normal")
                        .foregroundStyle(session.skipPermissions ? Palette.warning : Palette.success)
                }
            }
            .font(.system(size: 9))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.cardBackground))
    }
}
