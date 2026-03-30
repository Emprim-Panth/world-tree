import SwiftUI

/// Activity tab — full history of autonomous dispatch completions.
/// Shows every crew agent run, what it did, which project, and when.
struct DispatchActivityView: View {
    var store = DispatchActivityStore.shared
    @State private var expandedId: String?

    var body: some View {
        if store.recentCompletions.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 4) {
                ForEach(store.recentCompletions) { dispatch in
                    ActivityRow(
                        dispatch: dispatch,
                        isExpanded: expandedId == dispatch.id,
                        onTap: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                expandedId = expandedId == dispatch.id ? nil : dispatch.id
                            }
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No autonomous activity yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Completed crew dispatches will appear here")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Activity Row

private struct ActivityRow: View {
    let dispatch: WorldTreeDispatch
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 8) {
                statusIcon
                mainContent
                Spacer()
                timing
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            // Expandable result snippet
            if isExpanded, let result = dispatch.resultText, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(result.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .padding(.leading, 22)
            }
        }
        .background(Color.primary.opacity(isExpanded ? 0.05 : 0.025))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var statusIcon: some View {
        Image(systemName: dispatch.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(dispatch.status == .completed ? .green : .red)
            .frame(width: 14)
            .accessibilityLabel(dispatch.status == .completed ? "Completed" : "Failed")
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(dispatch.project)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)

                // Origin badge — distinguish autonomous crew work from manual dispatches
                if dispatch.origin == "heartbeat" {
                    Label("autonomous", systemImage: "bolt.circle")
                        .labelStyle(.titleOnly)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.cyan.opacity(0.12))
                        .cornerRadius(3)
                } else {
                    Text(dispatch.origin)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(3)
                }

                if let model = dispatch.model {
                    Text(model.components(separatedBy: "-").prefix(2).joined(separator: "-"))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Text(dispatch.displayMessage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? 3 : 1)
        }
    }

    private var timing: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let completedAt = dispatch.completedAt {
                Text(completedAt, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if let dur = dispatch.durationString {
                Text(dur)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
