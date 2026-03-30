import SwiftUI

/// Displays today's briefing, active alerts, and system health in the Command Center.
struct BriefingAlertsView: View {
    @ObservedObject private var briefingStore = BriefingStore.shared
    @ObservedObject private var healthStore = SystemHealthStore.shared
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    alertsSection
                    if briefingStore.todayBriefing != nil {
                        Divider()
                        briefingSection
                    }
                    Divider()
                    healthSection
                }
                .padding(.top, 4)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.cardBackground.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.cortana.opacity(0.2), lineWidth: 1))
        .onAppear {
            briefingStore.refresh()
            Task { await healthStore.runAllChecks() }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.checkered").font(.system(size: 10)).foregroundStyle(Palette.cortana)
            Text("Cortana Status").font(.system(size: 11, weight: .semibold))

            Spacer()

            if !isExpanded {
                inlineSummary
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
    }

    private var inlineSummary: some View {
        HStack(spacing: 8) {
            if briefingStore.alertCounts.critical > 0 {
                Label("\(briefingStore.alertCounts.critical)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9)).foregroundStyle(Palette.critical)
            }
            if briefingStore.alertCounts.warning > 0 {
                Label("\(briefingStore.alertCounts.warning)", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 9)).foregroundStyle(Palette.warning)
            }

            Image(systemName: healthStore.overallStatus.icon)
                .font(.system(size: 9))
                .foregroundStyle(healthStatusColor)
        }
    }

    // MARK: - Alerts

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "bell.badge").font(.system(size: 8)).foregroundStyle(.secondary)
                Text("Active Alerts").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if !briefingStore.activeAlerts.isEmpty {
                    Text("\(briefingStore.activeAlerts.count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if briefingStore.activeAlerts.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle").font(.system(size: 9)).foregroundStyle(Palette.success)
                    Text("All clear — no active alerts")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            } else {
                ForEach(briefingStore.activeAlerts.prefix(5)) { alert in
                    alertRow(alert)
                }
                if briefingStore.activeAlerts.count > 5 {
                    Text("+\(briefingStore.activeAlerts.count - 5) more")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func alertRow(_ alert: BriefingStore.Alert) -> some View {
        HStack(spacing: 6) {
            Image(systemName: alert.severityIcon)
                .font(.system(size: 9))
                .foregroundStyle(Palette.forStatus(alert.severity == "critical" ? "blocked" : alert.severity == "warning" ? "blocked" : "in_progress"))

            VStack(alignment: .leading, spacing: 1) {
                Text(alert.message)
                    .font(.system(size: 9)).lineLimit(2)
                HStack(spacing: 4) {
                    if let project = alert.project {
                        Text(project).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Text(alert.type).font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button {
                briefingStore.resolveAlert(id: alert.id)
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Resolve alert")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Briefing

    private var briefingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "doc.text").font(.system(size: 8)).foregroundStyle(.secondary)
                Text("Briefing").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let date = briefingStore.briefingDate {
                    Text(date, style: .date)
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }

            if let briefing = briefingStore.todayBriefing {
                Text(briefing.prefix(500))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Palette.cardBackground.opacity(0.3)))
            }
        }
    }

    // MARK: - Health

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "heart.text.square").font(.system(size: 8)).foregroundStyle(.secondary)
                Text("System Health").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if healthStore.isChecking {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        Task { await healthStore.runAllChecks() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 8))
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }

            if healthStore.checks.isEmpty {
                Text("Run health check to see status")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            } else {
                ForEach(healthStore.checks) { check in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(checkColor(check.status))
                            .frame(width: 6, height: 6)
                        Text(check.name)
                            .font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text(check.detail)
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        if let ms = check.latencyMs {
                            Text("\(ms)ms")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func checkColor(_ status: SystemHealthStore.HealthCheck.Status) -> Color {
        switch status {
        case .ok: return Palette.success
        case .warning: return Palette.warning
        case .error: return Palette.error
        case .unknown: return Palette.neutral
        }
    }

    private var healthStatusColor: Color {
        switch healthStore.overallStatus {
        case .healthy: return Palette.success
        case .degraded: return Palette.warning
        case .down: return Palette.error
        case .unknown: return Palette.neutral
        }
    }
}
