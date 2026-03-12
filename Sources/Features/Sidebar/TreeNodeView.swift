import SwiftUI

/// Recursive tree node for branch hierarchy in sidebar
struct TreeNodeView: View {
    let branch: Branch
    let treeId: String
    @Environment(AppState.self) var appState

    @State private var isHovering = false

    private var isSelected: Bool {
        appState.selectedBranchId == branch.id
    }

    var body: some View {
        if branch.children.isEmpty {
            // Leaf node
            branchRow
        } else {
            // Parent node with disclosure
            DisclosureGroup {
                ForEach(branch.children) { child in
                    TreeNodeView(branch: child, treeId: treeId)
                }
            } label: {
                branchRow
            }
        }
    }

    private var activeStreamEntry: GlobalStreamRegistry.StreamEntry? {
        guard ProcessingRegistry.shared.isProcessing(branch.id) else { return nil }
        return GlobalStreamRegistry.shared.streamEntry(for: branch.id)
    }

    /// Build the sidebar preview label given a stream entry and current time.
    /// - Shows active tool name + elapsed time when a tool is running.
    /// - Shows last text content when idle between tool calls.
    /// - Falls back to "Working · Xs" so long tool chains are always visible.
    private func streamingLabel(entry: GlobalStreamRegistry.StreamEntry, at date: Date) -> String {
        let elapsed = Int(date.timeIntervalSince(entry.startedAt))
        let elapsedStr = elapsed < 60
            ? "\(elapsed)s"
            : "\(elapsed / 60)m \(elapsed % 60)s"

        if let tool = entry.currentTool {
            // Strip trailing "…" suffix the ToolActivity description may add, then re-add own suffix
            let clean = tool.hasSuffix("…") ? String(tool.dropLast()) : tool
            return "⚙ \(clean) · \(elapsedStr)"
        }
        let content = entry.latestContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            return "Working · \(elapsedStr)"
        }
        return String(content.suffix(80))
    }

    private var branchRow: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                branchIcon
                    .font(.caption)
                    .foregroundStyle(iconColor)

                Text(branch.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                // Green dot when this branch has a live terminal process
                if BranchTerminalManager.shared.isActive(branchId: branch.id) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .help("Terminal active")
                        .accessibilityLabel("Terminal active")
                }

                statusIndicator
            }

            // Streaming preview — updates every 5s via TimelineView so elapsed time
            // stays live even during long tool executions (cargo build, etc.) where
            // no text tokens are flowing and the sidebar would otherwise look frozen.
            if let entry = activeStreamEntry {
                TimelineView(.periodic(from: .now, by: 5.0)) { context in
                    let label = streamingLabel(entry: entry, at: context.date)
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .italic()
                        .padding(.leading, 16)
                        .accessibilityLabel("Working: \(label)")
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            appState.selectBranch(branch.id, in: treeId)
        }
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    isSelected ? Color.accentColor.opacity(0.15) :
                    isHovering ? Color.accentColor.opacity(0.07) : Color.clear
                )
                .animation(.easeInOut(duration: 0.12), value: isSelected)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
        .cornerRadius(4)
        .contextMenu {
            Menu("Export") {
                Menu("Copy to Clipboard") {
                    ForEach(BranchExportFormat.allCases, id: \.self) { format in
                        Button(format.displayName) {
                            BranchExportService.shared.copyToClipboard(branchId: branch.id, format: format)
                        }
                    }
                }
                Menu("Save to File") {
                    ForEach(BranchExportFormat.allCases, id: \.self) { format in
                        Button(format.displayName) {
                            BranchExportService.shared.saveToFile(branchId: branch.id, format: format)
                        }
                    }
                }
            }
        }
    }

    private var branchIcon: some View {
        Group {
            switch branch.branchType {
            case .conversation:
                Image(systemName: "bubble.left")
                    .accessibilityLabel("Conversation branch")
            case .implementation:
                Image(systemName: "gearshape")
                    .accessibilityLabel("Implementation branch")
            case .exploration:
                Image(systemName: "magnifyingglass")
                    .accessibilityLabel("Exploration branch")
            }
        }
    }

    private var iconColor: Color {
        switch branch.branchType {
        case .conversation: .blue
        case .implementation: .orange
        case .exploration: .purple
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch branch.status {
        case .active:
            ActivityPulse(
                eventCount: EventStore.shared.activityCount(branchId: branch.id),
                isResponding: ProcessingRegistry.shared.isProcessing(branch.id)
            )
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .accessibilityLabel("Completed")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .accessibilityLabel("Failed")
        case .archived:
            Image(systemName: "archivebox")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Archived")
        }
    }
}
