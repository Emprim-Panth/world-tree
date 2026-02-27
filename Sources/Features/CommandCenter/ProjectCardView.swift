import SwiftUI

/// Per-project status card in the Command Center.
/// Shows project name, type, active task count, git branch, and last activity.
struct ProjectCardView: View {
    let activity: ProjectActivity
    @State private var isExpanded = false

    private var project: CachedProject { activity.project }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack(spacing: 8) {
                // Status dot
                Circle()
                    .fill(activity.isActive ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(activity.isActive ? "Active" : "Inactive")

                // Project icon + name
                Image(systemName: project.type.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(activity.isActive ? .primary : .secondary)

                Text(project.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                // Active task count badge
                if activity.totalActiveTasks > 0 {
                    Text("\(activity.totalActiveTasks)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.green)
                        .clipShape(Capsule())
                        .accessibilityLabel("\(activity.totalActiveTasks) active tasks")
                }
            }

            // Info row
            HStack(spacing: 8) {
                if let branch = project.gitBranch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8))
                        Text(branch)
                            .lineLimit(1)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                if project.gitDirty {
                    Text("modified")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Uncommitted changes")
                }

                Spacer()

                // Last activity
                if let date = activity.lastActivityDate {
                    Text(date, style: .relative)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            // Active work summary (when expanded or has active tasks)
            if activity.isActive || isExpanded {
                VStack(alignment: .leading, spacing: 4) {
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
                            if let dur = dispatch.durationString {
                                Text(dur)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }

                    ForEach(activity.activeTmuxSessions.filter(\.isClaudeSession)) { session in
                        HStack(spacing: 6) {
                            Image(systemName: "brain")
                                .font(.system(size: 8))
                                .foregroundStyle(.cyan)
                            Text(session.name)
                                .font(.system(size: 9, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            if let tokens = session.estimatedTokens, tokens > 0 {
                                ContextGauge(
                                    usage: Double(tokens) / Double(ContextPressureEstimator.maxContextTokens),
                                    estimatedTokens: tokens
                                )
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(activity.isActive
                      ? Color.accentColor.opacity(0.06)
                      : Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(activity.isActive ? Color.accentColor.opacity(0.2) : .clear, lineWidth: 1)
        )
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(project.name) project card")
        .accessibilityHint(isExpanded ? "Tap to collapse details" : "Tap to expand details")
    }
}
