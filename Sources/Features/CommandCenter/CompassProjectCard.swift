import SwiftUI

/// Enhanced project card powered by Compass state.
/// Shows goal, phase, git status, tickets, blockers, and recent decisions.
/// Falls back gracefully when Compass data isn't available.
struct CompassProjectCard: View {
    let activity: ProjectActivity
    let compassState: CompassState?
    let ticketCount: Int
    let blockedCount: Int
    var onSelect: (() -> Void)?

    @State private var isExpanded = false

    private var project: CachedProject { activity.project }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            phaseAndGoal
            gitRow
            ticketRow
            blockerRow

            if isExpanded {
                expandedContent
            }
        }
        .padding(10)
        .background(cardBackground)
        .overlay(cardBorder)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Toggle project details for \(project.name)")
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
        .contextMenu {
            if let onSelect {
                Button("Open Project") { onSelect() }
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Status: \(statusLabel)")

            Image(systemName: project.type.icon)
                .font(.system(size: 11))
                .foregroundStyle(activity.isActive ? .primary : .secondary)

            Text(project.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Spacer()

            // Phase badge
            if let phase = compassState?.currentPhase, phase != "unknown" {
                Text(phase)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(phaseColor(phase))
                    .clipShape(Capsule())
            }

            // Active task count
            if activity.totalActiveTasks > 0 {
                Text("\(activity.totalActiveTasks)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green)
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Goal & Phase

    @ViewBuilder
    private var phaseAndGoal: some View {
        if let goal = compassState?.currentGoal {
            Text(goal)
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(2)
        }
    }

    // MARK: - Git

    private var gitRow: some View {
        HStack(spacing: 8) {
            if let branch = compassState?.gitBranch ?? project.gitBranch {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8))
                    Text(branch)
                        .lineLimit(1)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            if let state = compassState, state.isDirty {
                Text("\(state.gitUncommittedCount) uncommitted")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            } else if project.gitDirty {
                Text("modified")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }

            Spacer()

            if let commit = compassState?.gitLastCommit {
                Text(commit)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .trailing)
            }
        }
    }

    // MARK: - Tickets

    @ViewBuilder
    private var ticketRow: some View {
        if ticketCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "ticket")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)

                Text("\(ticketCount) open")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                if blockedCount > 0 {
                    Text("\(blockedCount) blocked")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.red)
                }

                Spacer()

                if let next = compassState?.nextTicket {
                    Text("next: \(next)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    // MARK: - Blockers

    @ViewBuilder
    private var blockerRow: some View {
        if let state = compassState, !state.blockers.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.red)
                Text(state.blockers.joined(separator: ", "))
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.8))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            // Last session
            if let summary = compassState?.lastSessionSummary {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Text(summary)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            // Recent decisions
            if let state = compassState, !state.decisions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Decisions:")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(state.decisions.prefix(3), id: \.self) { decision in
                        HStack(alignment: .top, spacing: 4) {
                            Text("•")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(decision)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }

            // Active dispatches
            ForEach(activity.activeDispatches) { dispatch in
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 10, height: 10)
                    Text(dispatch.displayMessage)
                        .font(.system(size: 9, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Styling

    private var statusColor: Color {
        if let state = compassState, !state.blockers.isEmpty { return .red }
        if activity.isActive { return .green }
        if compassState?.isDirty == true { return .orange }
        return .gray.opacity(0.4)
    }

    private var statusLabel: String {
        if let state = compassState, !state.blockers.isEmpty { return "blocked" }
        if activity.isActive { return "active" }
        if compassState?.isDirty == true { return "modified" }
        return "inactive"
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(cardFillColor)
    }

    private var cardFillColor: Color {
        if let state = compassState, !state.blockers.isEmpty {
            return Color.red.opacity(0.06)
        }
        if activity.isActive {
            return Color.accentColor.opacity(0.06)
        }
        return Color(NSColor.controlBackgroundColor).opacity(0.5)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(borderColor, lineWidth: 1)
    }

    private var borderColor: Color {
        if let state = compassState, !state.blockers.isEmpty {
            return .red.opacity(0.3)
        }
        if activity.isActive {
            return Color.accentColor.opacity(0.2)
        }
        return .clear
    }

    private func phaseColor(_ phase: String) -> Color {
        switch phase {
        case "implementing": return .blue
        case "debugging": return .orange
        case "testing": return .purple
        case "shipping": return .green
        case "planning": return .cyan
        case "exploring": return .indigo
        default: return .gray
        }
    }
}
