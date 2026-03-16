import SwiftUI

/// Real-time status card for a running agent session.
/// Designed to sit in a LazyVGrid alongside CompassProjectCard.
struct AgentStatusCard: View {
    let session: AgentSession
    var health: SessionHealth?
    var onTap: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            projectRow
            taskRow
            fileRow
            contextBar
            footerRow
        }
        .padding(10)
        .frame(minHeight: 120)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(statusColor(for: session.status).opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .contextMenu {
            Button {
                onTap?()
            } label: {
                Label("Focus Terminal", systemImage: "terminal")
            }
            Button {
                showMemory = true
            } label: {
                Label("Session Memory", systemImage: "brain")
            }
        }
        .popover(isPresented: $showMemory) {
            SessionMemoryView(session: session)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    @State private var showMemory = false

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            // Agent name badge
            Circle()
                .fill(statusColor(for: session.status))
                .frame(width: 8, height: 8)

            Text(session.agentName ?? "Interactive")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Spacer()

            // Status pill
            HStack(spacing: 3) {
                Image(systemName: statusIcon(for: session.status))
                    .font(.system(size: 9))
                Text(session.status.rawValue.replacingOccurrences(of: "_", with: " "))
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(statusColor(for: session.status))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor(for: session.status).opacity(0.12))
            .clipShape(Capsule())

            // Duration
            if let dur = session.duration {
                Text(formatDuration(dur))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Project

    private var projectRow: some View {
        Text(session.project)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    // MARK: - Task

    @ViewBuilder
    private var taskRow: some View {
        if let task = session.currentTask {
            Text(task)
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(2)
        }
    }

    // MARK: - File

    @ViewBuilder
    private var fileRow: some View {
        if let file = session.currentFile {
            HStack(spacing: 3) {
                Text("\u{25C6}")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text(file)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Context Bar

    private var contextBar: some View {
        let pct = session.contextPercentage
        return HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.08))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(contextColor(pct))
                        .frame(width: geo.size.width * min(pct, 1.0))
                }
            }
            .frame(height: 4)

            Text("\(Int(pct * 100))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(contextColor(pct))
                .frame(width: 30, alignment: .trailing)
        }
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 10) {
            // Health badge
            SessionHealthBadge(health: health, size: 8)

            // Tokens
            HStack(spacing: 2) {
                Image(systemName: "circle.grid.3x3")
                    .font(.system(size: 8))
                Text(formatTokenCount(session.totalTokens))
                    .font(.system(size: 9, design: .monospaced))
            }
            .foregroundStyle(.secondary)

            // Errors (only when > 0)
            if session.errorCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 8))
                    Text("\(session.errorCount)")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.red)
            }

            // Files changed
            let fileCount = session.filesChangedArray.count
            if fileCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 8))
                    Text("\(fileCount)")
                        .font(.system(size: 9, design: .monospaced))
                }
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        let name = session.agentName ?? "Interactive"
        let status = session.status.rawValue.replacingOccurrences(of: "_", with: " ")
        let dur = session.duration.map { formatDuration($0) } ?? "unknown duration"
        return "\(name) on \(session.project): \(status), running for \(dur)"
    }

    // MARK: - Helpers

    private func statusColor(for status: AgentSessionStatus) -> Color {
        switch status {
        case .starting:     return .secondary
        case .thinking:     return .blue
        case .writing:      return .green
        case .toolUse:      return .cyan
        case .waiting:      return .orange
        case .stuck:        return .red
        case .idle:         return .secondary
        case .completed:    return .green
        case .failed:       return .red
        case .interrupted:  return .orange
        }
    }

    private func statusIcon(for status: AgentSessionStatus) -> String {
        switch status {
        case .starting:     return "play.circle"
        case .thinking:     return "brain"
        case .writing:      return "pencil.line"
        case .toolUse:      return "terminal"
        case .waiting:      return "hourglass"
        case .stuck:        return "exclamationmark.triangle"
        case .idle:         return "moon.zzz"
        case .completed:    return "checkmark.circle"
        case .failed:       return "xmark.circle"
        case .interrupted:  return "stop.circle"
        }
    }

    private func contextColor(_ pct: Double) -> Color {
        if pct > 0.9 { return .red }
        if pct > 0.7 { return .yellow }
        return .green
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count < 1_000 { return "\(count)" }
        if count < 1_000_000 {
            let k = Double(count) / 1_000
            return k < 10 ? String(format: "%.1fK", k) : "\(Int(k))K"
        }
        let m = Double(count) / 1_000_000
        return String(format: "%.1fM", m)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        if interval < 60 { return "\(Int(interval))s" }
        let minutes = Int(interval) / 60
        let hours = minutes / 60
        if hours == 0 { return "\(minutes)m" }
        return "\(hours)h \(minutes % 60)m"
    }
}
