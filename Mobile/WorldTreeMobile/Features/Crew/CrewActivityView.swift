import SwiftUI

// MARK: - CrewActivityView

/// Mobile view showing live Starfleet crew dispatch activity.
/// Fetches from the Mac's /api/crew endpoint and auto-refreshes every 30s.
struct CrewActivityView: View {
    @Environment(ConnectionManager.self) private var connectionManager
    @State private var crewStore = CrewStore()
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if crewStore.isLoading && crewStore.jobs.isEmpty {
                    ProgressView("Loading crew…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = crewStore.lastError, crewStore.jobs.isEmpty {
                    ContentUnavailableView(
                        "Can't reach server",
                        systemImage: "wifi.slash",
                        description: Text(error)
                    )
                } else {
                    crewList
                }
            }
            .navigationTitle("Crew")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: crewStore.isLoading ? "arrow.clockwise" : "arrow.clockwise")
                            
                    }
                    .disabled(crewStore.isLoading)
                }
            }
        }
        .task { await startAutoRefresh() }
        .onDisappear { refreshTask?.cancel() }
    }

    // MARK: - List

    private var crewList: some View {
        List {
            // Summary header
            if let hb = crewStore.heartbeat {
                Section {
                    heartbeatRow(hb)
                }
            }

            // Active jobs
            if !crewStore.activeJobs.isEmpty {
                Section {
                    ForEach(crewStore.activeJobs) { job in
                        CrewJobRow(job: job)
                    }
                } header: {
                    HStack {
                        Text("Active")
                        Spacer()
                        Text("\(crewStore.activeJobs.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Governance
            if !crewStore.governance.isEmpty {
                Section("Governance") {
                    ForEach(crewStore.governance.prefix(5)) { entry in
                        GovernanceRow(entry: entry)
                    }
                }
            }

            // Recent completed/failed
            if !crewStore.doneJobs.isEmpty {
                Section {
                    ForEach(crewStore.doneJobs.prefix(15)) { job in
                        CrewJobRow(job: job)
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        if let updated = crewStore.lastUpdated {
                            Text("Updated \(updated, style: .relative) ago")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            if crewStore.jobs.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "moon.zzz.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No recent crew activity")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 20)
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await refresh() }
    }

    // MARK: - Heartbeat Row

    private func heartbeatRow(_ hb: CrewHeartbeat) -> some View {
        HStack(spacing: 12) {
            Image(systemName: intensityIcon(hb.intensity))
                .font(.title3)
                .foregroundStyle(intensityColor(hb.intensity))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hb.intensity.capitalized)
                        .font(.subheadline.weight(.semibold))
                    Text("heartbeat")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if hb.signalsFound > 0 {
                        Label("\(hb.signalsFound) signals", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Label("Quiet", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if hb.dispatchesMade > 0 {
                        Label("\(hb.dispatchesMade) dispatched", systemImage: "paperplane")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            if let ts = hb.startedAt {
                Text(ts.prefix(16))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Auto Refresh

    private func startAutoRefresh() async {
        await refresh()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }
    }

    private func refresh() async {
        guard let server = connectionManager.currentServer else { return }
        await crewStore.fetch(server: server)
    }

    // MARK: - Helpers

    private func intensityIcon(_ intensity: String) -> String {
        switch intensity {
        case "deep":   return "waveform.path.ecg"
        case "medium": return "waveform"
        default:       return "minus.circle"
        }
    }

    private func intensityColor(_ intensity: String) -> Color {
        switch intensity {
        case "deep":   return .purple
        case "medium": return .blue
        default:       return .gray
        }
    }
}

// MARK: - CrewJobRow

private struct CrewJobRow: View {
    let job: CrewJob

    var body: some View {
        HStack(spacing: 12) {
            // Agent avatar
            ZStack {
                Circle()
                    .fill(agentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Text(job.agentInitial)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(agentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.crewAgent)
                        .font(.subheadline.weight(.semibold))
                    Text("→")
                        .foregroundStyle(.tertiary)
                    Text(job.project)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(job.shortPrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    statusBadge
                    if let ticketId = job.ticketId {
                        Text(ticketId)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                    if job.status == "failed", let err = job.lastError {
                        Text(err.prefix(40))
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusBadge: some View {
        Text(job.status)
            .font(.caption2.weight(.medium))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.12))
            .clipShape(Capsule())
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

    private var agentColor: Color {
        switch job.crewAgent.lowercased() {
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

// MARK: - GovernanceRow

private struct GovernanceRow: View {
    let entry: CrewGovernance

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(entry.category.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let ts = entry.createdAt {
                    Text(ts.prefix(10))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(entry.shortContent)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.75))
        }
        .padding(.vertical, 2)
    }
}
