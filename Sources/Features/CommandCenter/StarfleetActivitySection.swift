import SwiftUI

// MARK: - StarfleetActivitySection

/// Command Center section — live view of Starfleet crew dispatch activity.
///
/// Shows what crew agents are doing right now (dispatch_queue) plus recent
/// heartbeat cycles and governance journal entries. Read-only — this is an
/// ops dashboard, not a dispatch interface.
struct StarfleetActivitySection: View {
    @ObservedObject private var heartbeat = HeartbeatStore.shared
    @State private var isExpanded = true
    @State private var showAllJobs = false

    private var activeJobs: [CrewDispatchJob] {
        heartbeat.dispatchJobs.filter { $0.status == "running" || $0.status == "pending" }
    }

    private var recentJobs: [CrewDispatchJob] {
        heartbeat.dispatchJobs.filter { $0.status == "completed" || $0.status == "failed" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader

            if isExpanded {
                dispatchSection
                if !heartbeat.recentRuns.isEmpty {
                    heartbeatSection
                }
                if !heartbeat.recentSignals.isEmpty {
                    governanceSection
                }
            }
        }
        .onAppear { heartbeat.refresh() }
    }

    // MARK: - Header

    private var sectionHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.3\(activeJobs.isEmpty ? "" : ".fill")")
                    .font(.system(size: 10))
                    .foregroundStyle(activeJobs.isEmpty ? Color.secondary : Color.purple)

                Text("CREW")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                if !activeJobs.isEmpty {
                    agentBadges
                }

                Spacer()

                if !activeJobs.isEmpty {
                    Text("\(activeJobs.count) active")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.12))
                        .cornerRadius(4)
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private var agentBadges: some View {
        let agents = Array(Set(activeJobs.compactMap { $0.crewAgent })).sorted().prefix(4)
        return HStack(spacing: 3) {
            ForEach(agents, id: \.self) { agent in
                Text(agent.prefix(1).uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(agentColor(agent))
                    .clipShape(Circle())
            }
        }
    }

    // MARK: - Dispatch Section

    private var dispatchSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            let displayJobs = showAllJobs
                ? heartbeat.dispatchJobs
                : Array(heartbeat.dispatchJobs.prefix(8))

            if displayJobs.isEmpty {
                emptyState
            } else {
                ForEach(displayJobs) { job in
                    DispatchJobRow(job: job)
                }

                if heartbeat.dispatchJobs.count > 8 && !showAllJobs {
                    Button("Show \(heartbeat.dispatchJobs.count - 8) more…") {
                        showAllJobs = true
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Text("No active crew dispatches")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(6)
    }

    // MARK: - Heartbeat Section

    private var heartbeatSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HEARTBEAT")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)

            ForEach(heartbeat.recentRuns.prefix(4)) { run in
                HeartbeatRunRow(run: run)
            }
        }
    }

    // MARK: - Governance Section

    private var governanceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GOVERNANCE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)

            ForEach(heartbeat.recentSignals.prefix(3)) { signal in
                GovernanceRow(signal: signal)
            }
        }
    }

    // MARK: - Helpers

    private func agentColor(_ agent: String) -> Color {
        switch agent.lowercased() {
        case "geordi":  return .blue
        case "data":    return .cyan
        case "scotty":  return .orange
        case "worf":    return .red
        case "torres":  return .purple
        case "spock":   return .indigo
        case "dax":     return .teal
        case "uhura":   return .mint
        default:        return .gray
        }
    }
}

// MARK: - DispatchJobRow

private struct DispatchJobRow: View {
    let job: CrewDispatchJob

    var body: some View {
        HStack(spacing: 8) {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            // Agent icon
            Image(systemName: job.agentIcon)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            // Agent name
            Text(job.crewAgent)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, alignment: .leading)

            // Project
            Text(job.project)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 80, alignment: .leading)

            // Prompt (truncated)
            Text(job.shortPrompt)
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Attempts indicator
            if job.status == "failed" || job.attempts > 1 {
                Text("\(job.attempts)/\(job.maxAttempts)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(job.status == "failed" ? .red : .orange)
            }

            // Ticket badge
            if let ticketId = job.ticketId {
                Text(ticketId)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(3)
            }

            // Time
            if let createdAt = job.createdAt {
                Text(createdAt, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(statusBackground)
        .cornerRadius(5)
        .help(job.status == "failed" ? (job.lastError ?? "Failed") : job.prompt)
    }

    private var statusColor: Color {
        switch job.status {
        case "running":   return .blue
        case "pending":   return .orange
        case "completed": return .green
        case "failed":    return .red
        default:          return .gray
        }
    }

    private var statusBackground: Color {
        switch job.status {
        case "running": return Color.blue.opacity(0.05)
        case "failed":  return Color.red.opacity(0.05)
        default:        return Color.primary.opacity(0.03)
        }
    }
}

// MARK: - HeartbeatRunRow

private struct HeartbeatRunRow: View {
    let run: HeartbeatRun

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: intensityIcon)
                .font(.system(size: 9))
                .foregroundStyle(intensityColor)
                .frame(width: 12)

            Text(run.intensity)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            if run.signalsFound > 0 {
                Text("\(run.signalsFound) signals")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            } else {
                Text("quiet")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if run.dispatchesMade > 0 {
                Text("· \(run.dispatchesMade) dispatched")
                    .font(.system(size: 10))
                    .foregroundStyle(.blue)
            }

            Spacer()

            if let startedAt = run.startedAt {
                Text(startedAt, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private var intensityIcon: String {
        switch run.intensity {
        case "deep":   return "waveform.path.ecg"
        case "medium": return "waveform"
        default:       return "minus"
        }
    }

    private var intensityColor: Color {
        switch run.intensity {
        case "deep":   return .purple
        case "medium": return .blue
        default:       return .secondary
        }
    }
}

// MARK: - GovernanceRow

private struct GovernanceRow: View {
    let signal: HeartbeatSignal

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .frame(width: 12)
                .padding(.top, 1)

            Text(signal.content.components(separatedBy: "\n").first ?? signal.content)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }
}
