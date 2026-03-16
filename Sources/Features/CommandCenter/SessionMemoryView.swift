import SwiftUI
import GRDB

/// Visual representation of an agent session's context window, files in context,
/// knowledge injected, decisions made, and compaction events.
/// Shown as a popover from AgentStatusCard secondary action.
struct SessionMemoryView: View {
    let session: AgentSession

    @State private var fileTouches: [AgentFileTouch] = []
    @State private var compactionCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            contextBar
            filesSection
            tokenSection
            compactionSection
            sessionMeta
        }
        .padding(16)
        .frame(width: 400)
        .frame(minHeight: 250)
        .background(.ultraThinMaterial)
        .onAppear { loadData() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 14))
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 1) {
                Text("Session Memory")
                    .font(.system(size: 13, weight: .semibold))

                Text("\(session.agentName ?? "Interactive") on \(session.project)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Context Bar

    private var contextBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CONTEXT WINDOW")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)

            let pct = session.contextPercentage
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.08))

                        RoundedRectangle(cornerRadius: 3)
                            .fill(contextColor(pct))
                            .frame(width: geo.size.width * min(pct, 1.0))
                    }
                }
                .frame(height: 8)

                Text("\(Int(pct * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(contextColor(pct))

                Text("(\(formatTokens(session.contextUsed)) / \(formatTokens(session.contextMax)))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Files

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("FILES TOUCHED (\(fileTouches.count))")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            if fileTouches.isEmpty {
                Text("No file activity recorded")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                let displayed = Array(fileTouches.prefix(8))
                ForEach(displayed, id: \.id) { touch in
                    HStack(spacing: 4) {
                        Image(systemName: actionIcon(touch.action))
                            .font(.system(size: 9))
                            .foregroundStyle(actionColor(touch.action))
                            .frame(width: 12)

                        Text(shortenPath(touch.filePath))
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                }

                if fileTouches.count > 8 {
                    Text("... \(fileTouches.count - 8) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Tokens

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TOKEN USAGE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)

            HStack(spacing: 16) {
                tokenPill("In", value: session.tokensIn, color: .blue)
                tokenPill("Out", value: session.tokensOut, color: .green)
                tokenPill("Total", value: session.totalTokens, color: .primary)
            }
        }
    }

    private func tokenPill(_ label: String, value: Int, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(formatTokens(value))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Compaction

    private var compactionSection: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("Compaction Events: \(compactionCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Session Meta

    private var sessionMeta: some View {
        HStack(spacing: 16) {
            if let dur = session.duration {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text(formatDuration(dur))
                        .font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
            }

            if session.errorCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                    Text("\(session.errorCount) errors")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.red.opacity(0.7))
            }

            Spacer()
        }
    }

    // MARK: - Data Loading

    private func loadData() {
        do {
            fileTouches = try DatabaseManager.shared.read { db in
                guard try db.tableExists("agent_file_touches") else { return [] }
                return try AgentFileTouch.fetchAll(db, sql: """
                    SELECT * FROM agent_file_touches
                    WHERE session_id = ?
                    ORDER BY touched_at DESC
                    """, arguments: [session.id])
            }
        } catch {
            wtLog("[SessionMemoryView] Failed to load file touches: \(error)")
        }

        do {
            let rows = try DatabaseManager.shared.read { db -> [Row] in
                guard try db.tableExists("canvas_token_usage") else { return [] }
                return try Row.fetchAll(db, sql: """
                    SELECT input_tokens FROM canvas_token_usage
                    WHERE session_id = ?
                    ORDER BY created_at ASC
                    """, arguments: [session.id])
            }

            var compactions = 0
            var prevInput = 0
            for row in rows {
                let input: Int = row["input_tokens"] ?? 0
                if prevInput > 0 && input < prevInput && (prevInput - input) > 50_000 {
                    compactions += 1
                }
                prevInput = input
            }
            compactionCount = compactions
        } catch {
            wtLog("[SessionMemoryView] Failed to load token history: \(error)")
        }
    }

    // MARK: - Helpers

    private func contextColor(_ pct: Double) -> Color {
        if pct > 0.9 { return .red }
        if pct > 0.7 { return .yellow }
        return .green
    }

    private func formatTokens(_ count: Int) -> String {
        if count < 1_000 { return "\(count)" }
        if count < 1_000_000 { return "\(count / 1_000)K" }
        return String(format: "%.1fM", Double(count) / 1_000_000)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let hours = minutes / 60
        if hours == 0 { return "\(minutes)m \(Int(interval) % 60)s" }
        return "\(hours)h \(minutes % 60)m"
    }

    private func shortenPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count <= 3 { return path }
        return ".../" + components.suffix(3).joined(separator: "/")
    }

    private func actionIcon(_ action: String) -> String {
        switch action {
        case "edit": return "pencil"
        case "create": return "plus"
        case "delete": return "trash"
        case "read": return "eye"
        default: return "doc"
        }
    }

    private func actionColor(_ action: String) -> Color {
        switch action {
        case "edit": return .blue
        case "create": return .green
        case "delete": return .red
        case "read": return .secondary
        default: return .secondary
        }
    }
}
