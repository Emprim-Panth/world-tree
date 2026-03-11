import SwiftUI

/// Live view of all in-progress LLM conversations across every branch.
///
/// Appears at the top of the Command Center when any branch is streaming.
/// Each row shows the project, current tool (if any), and a rolling preview
/// of the response being written. Tap to navigate directly to that branch.
struct LiveStreamsSection: View {
    @Environment(AppState.self) var appState
    private var registry = GlobalStreamRegistry.shared

    var body: some View {
        let streams = registry.activeStreams
        if !streams.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(count: streams.count)
                VStack(spacing: 4) {
                    ForEach(streams) { entry in
                        liveStreamRow(entry)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private func sectionHeader(count: Int) -> some View {
        HStack(spacing: 6) {
            // Pulsing dot to distinguish live streams from static sections
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
                .opacity(0.9)
            Text("LIVE STREAMS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.green)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) live stream\(count == 1 ? "" : "s")")
    }

    // MARK: - Row

    private func liveStreamRow(_ entry: GlobalStreamRegistry.StreamEntry) -> some View {
        Button {
            if let treeId = entry.treeId {
                appState.selectBranch(entry.id, in: treeId)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                // Spinner
                ProgressView()
                    .scaleEffect(0.45)
                    .frame(width: 12, height: 12)
                    .padding(.top, 2)
                    .accessibilityLabel("Streaming")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        // Project badge
                        if let project = entry.projectName {
                            Text(project)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.75))
                                .clipShape(Capsule())
                        }

                        // Tool label (if a tool is running)
                        if let tool = entry.currentTool {
                            Text("◆ \(tool)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        // Elapsed time
                        Text(elapsed(since: entry.startedAt))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    // Response preview — last ~200 chars
                    if !entry.latestContent.isEmpty {
                        let preview = String(entry.latestContent.suffix(200))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !preview.isEmpty {
                            Text(preview)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        // Nothing yet — show thinking indicator
                        Text("Thinking…")
                            .font(.system(size: 9).italic())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(entry.treeId == nil)
        .help(entry.treeId == nil ? "Navigate to branch" : "Open \(entry.projectName ?? "conversation")")
        .accessibilityLabel("Live stream in \(entry.projectName ?? "unknown project")")
        .accessibilityHint(entry.treeId != nil ? "Tap to open conversation" : "")
    }

    // MARK: - Helpers

    private func elapsed(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m\(seconds % 60)s"
    }
}
