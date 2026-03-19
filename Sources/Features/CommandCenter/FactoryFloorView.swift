import SwiftUI
import GRDB

// MARK: - Factory Floor View

/// Mission Control — live production pipeline.
/// Shows all dispatch_queue tasks as a Kanban board with agent attribution,
/// model tags, and per-column counts. Data from HeartbeatStore (reads dispatch_queue).
struct FactoryFloorView: View {
    @ObservedObject private var heartbeatStore = HeartbeatStore.shared
    @State private var avgPipelineTime: String = "—"
    @State private var shippedToday: Int = 0
    @State private var lastRefreshed: Date = Date()

    private var pending: [CrewDispatchJob] {
        heartbeatStore.dispatchJobs.filter { $0.status == "pending" }
    }
    private var running: [CrewDispatchJob] {
        heartbeatStore.dispatchJobs.filter { $0.status == "running" }
    }
    private var completed: [CrewDispatchJob] {
        heartbeatStore.dispatchJobs.filter { $0.status == "completed" }
    }
    private var failed: [CrewDispatchJob] {
        heartbeatStore.dispatchJobs.filter { $0.status == "failed" || $0.status == "exhausted" }
    }
    private var blocked: [CrewDispatchJob] {
        heartbeatStore.dispatchJobs.filter { $0.status == "blocked" }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            summaryStrip
            Divider()
            kanban
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            Task {
                await heartbeatStore.refreshAsync()
                loadMetrics()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await heartbeatStore.refreshAsync()
                loadMetrics()
                lastRefreshed = Date()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.cyan)
                    Text("Factory Floor")
                        .font(.title2)
                        .fontWeight(.bold)
                }
                Text("Production pipeline — all autonomous work")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Last refresh
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("Refreshes every 15s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button {
                Task {
                    await heartbeatStore.refreshAsync()
                    loadMetrics()
                    lastRefreshed = Date()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Refresh pipeline")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Summary Strip

    private var summaryStrip: some View {
        HStack(spacing: 0) {
            summaryTile(value: "\(shippedToday)", label: "SHIPPED TODAY", icon: "checkmark.circle.fill", color: .green)
            Divider().frame(height: 40)
            summaryTile(value: "\(running.count)", label: "IN PROGRESS", icon: "bolt.fill", color: .cyan)
            Divider().frame(height: 40)
            summaryTile(value: "\(pending.count)", label: "BACKLOG", icon: "tray.full", color: .orange)
            Divider().frame(height: 40)
            summaryTile(value: "\(blocked.count)", label: "BLOCKED", icon: "exclamationmark.triangle", color: blocked.isEmpty ? .secondary : .red)
            Divider().frame(height: 40)
            summaryTile(value: avgPipelineTime, label: "AVG PIPELINE", icon: "timer", color: .purple)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func summaryTile(value: String, label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    // MARK: - Kanban

    private var kanban: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                KanbanColumn(
                    title: "BACKLOG",
                    subtitle: "Waiting to run",
                    icon: "tray.full",
                    accentColor: .orange,
                    jobs: pending
                )
                KanbanColumn(
                    title: "BUILDING",
                    subtitle: "Active work",
                    icon: "bolt.fill",
                    accentColor: .cyan,
                    jobs: running
                )
                KanbanColumn(
                    title: "FAILED",
                    subtitle: "Needs attention",
                    icon: "exclamationmark.triangle.fill",
                    accentColor: .red,
                    jobs: failed
                )
                KanbanColumn(
                    title: "DONE",
                    subtitle: "Completed",
                    icon: "checkmark.circle.fill",
                    accentColor: .green,
                    jobs: Array(completed.prefix(20))
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Metrics

    private func loadMetrics() {
        Task {
            do {
                let (shipped, avgMs) = try await DatabaseManager.shared.readAsync { db -> (Int, Double?) in
                    // Shipped today
                    let today = Calendar.current.startOfDay(for: Date())
                    let todayStr = ISO8601DateFormatter().string(from: today).prefix(10)
                    let shippedRow = try Row.fetchOne(db, sql: """
                        SELECT COUNT(*) as n FROM dispatch_queue
                        WHERE status = 'completed' AND date(updated_at) >= date('now', 'localtime')
                        """)
                    let shippedCount = (shippedRow?["n"] as? Int64).map(Int.init) ?? 0

                    // Avg pipeline time (ms) from completed tasks with created_at + updated_at
                    let avgRow = try Row.fetchOne(db, sql: """
                        SELECT AVG(
                            (julianday(updated_at) - julianday(created_at)) * 86400 * 1000
                        ) as avg_ms
                        FROM dispatch_queue
                        WHERE status = 'completed' AND updated_at IS NOT NULL AND created_at IS NOT NULL
                        LIMIT 1
                        """)
                    let avg = avgRow?["avg_ms"] as? Double
                    return (shippedCount, avg)
                }
                await MainActor.run {
                    self.shippedToday = shipped
                    if let ms = avgMs, ms > 0 {
                        let mins = Int(ms / 60_000)
                        let hrs  = mins / 60
                        let rem  = mins % 60
                        self.avgPipelineTime = hrs > 0 ? "\(hrs)h \(rem)m" : "\(mins)m"
                    } else {
                        self.avgPipelineTime = "—"
                    }
                }
            } catch {
                // Metrics are best-effort
            }
        }
    }
}

// MARK: - Kanban Column

private struct KanbanColumn: View {
    let title: String
    let subtitle: String
    let icon: String
    let accentColor: Color
    let jobs: [CrewDispatchJob]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Column header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentColor)
                Spacer()
                // Count badge
                Text("\(jobs.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accentColor.opacity(0.8))
                    .clipShape(Capsule())
            }
            Text(subtitle)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            Divider()
                .overlay(accentColor.opacity(0.3))

            // Cards
            if jobs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("Nothing here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(jobs) { job in
                    DispatchJobCard(job: job, accentColor: accentColor)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 240, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accentColor.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Dispatch Job Card

private struct DispatchJobCard: View {
    let job: CrewDispatchJob
    let accentColor: Color

    private var timeAgo: String {
        guard let date = job.createdAt else { return "" }
        let diff = Int(Date().timeIntervalSince(date))
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(diff / 60)m ago" }
        if diff < 86400 { return "\(diff / 3600)h ago" }
        return "\(diff / 86400)d ago"
    }

    private var modelTag: String {
        switch job.model.lowercased() {
        case "codex", "codex-mini-latest", "openai": return "Codex"
        case "opus":                                  return "Opus"
        case "sonnet":                                return "Sonnet"
        case "ollama", "qwen2.5-coder:7b":            return "Ollama"
        default:                                      return job.model.isEmpty ? "Claude" : job.model
        }
    }

    private var modelColor: Color {
        switch modelTag {
        case "Codex":   return .purple
        case "Opus":    return .orange
        case "Ollama":  return .teal
        default:        return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Task description
            Text(job.shortPrompt)
                .font(.system(size: 12))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            // Metadata row
            HStack(spacing: 6) {
                // Agent
                Label(job.crewAgent.isEmpty ? "auto" : job.crewAgent.capitalized, systemImage: job.agentIcon)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                // Model tag
                Text(modelTag)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(modelColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(modelColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            // Project + time
            HStack(spacing: 4) {
                Text(job.project)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Text(timeAgo)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            // Progress bar for running tasks
            if job.status == "running" {
                ProgressBar(color: accentColor)
            }

            // Error snippet for failed tasks
            if let err = job.lastError, !err.isEmpty {
                Text(err.prefix(80))
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(accentColor.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(accentColor.opacity(0.10), lineWidth: 1)
        )
    }
}

// MARK: - Indeterminate Progress Bar

private struct ProgressBar: View {
    let color: Color
    @State private var offset: CGFloat = -1.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.12))
                    .frame(height: 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.6))
                    .frame(width: geo.size.width * 0.4, height: 3)
                    .offset(x: offset * geo.size.width)
            }
        }
        .frame(height: 3)
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                offset = 1.0
            }
        }
    }
}

// MARK: - DatabaseManager async helper

private extension DatabaseManager {
    func readAsync<T>(_ block: @escaping (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            do {
                let result = try self.read(block)
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
