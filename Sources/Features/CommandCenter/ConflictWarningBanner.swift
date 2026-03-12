import SwiftUI

// MARK: - Conflict Warning Banner

/// Amber warning card shown when two agents are editing the same file.
/// Lives inside AttentionPanel — only visible when conflicts exist.
struct ConflictWarningBanner: View {
    let conflict: ConflictDetector.FileConflict
    var onDismiss: (() -> Void)?
    var onViewDiff: ((String) -> Void)?     // called with session ID of most-recent agent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("FILE CONFLICT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                Spacer()
            }

            // File path
            Text(conflict.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)

            // Agents
            VStack(alignment: .leading, spacing: 3) {
                ForEach(conflict.agents) { agent in
                    agentRow(agent)
                }
            }

            // Advisory
            Text("Both agents are actively editing this file. Consider pausing one to avoid merge conflicts.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Actions
            HStack {
                Spacer()
                if let mostRecent = conflict.agents.first {
                    Button("View in Diff") {
                        onViewDiff?(mostRecent.sessionId)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.orange)
                }
                Button("Dismiss") {
                    onDismiss?()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("File conflict on \(conflict.filePath), involving \(conflict.agents.count) agents")
    }

    // MARK: - Agent Row

    private func agentRow(_ agent: ConflictDetector.ConflictingAgent) -> some View {
        HStack(spacing: 4) {
            Image(systemName: actionIcon(agent.action))
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text(agent.agentName ?? agent.sessionId.prefix(8).description)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
            Text(agent.action)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
            Text(agent.lastTouchAt, style: .relative)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func actionIcon(_ action: String) -> String {
        switch action {
        case "create": return "plus.circle"
        case "delete": return "minus.circle"
        default:       return "pencil.circle"
        }
    }
}
