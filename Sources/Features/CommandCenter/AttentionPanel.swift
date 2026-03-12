import SwiftUI

// MARK: - Attention Panel

/// Displays unacknowledged attention events — permission prompts, stuck agents, error loops.
/// Only renders when events exist. Designed to sit at the top of CommandCenterView.
struct AttentionPanel: View {
    @ObservedObject var store: AttentionStore = .shared

    var body: some View {
        if store.unacknowledged.isEmpty {
            EmptyView()
        } else {
            panel
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut, value: store.unacknowledged.count)
        }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Divider()
            eventList
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.red.opacity(store.criticalCount > 0 ? 0.4 : 0.0), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)

                Text("ATTENTION")
                    .font(.caption)
                    .fontWeight(.bold)
                    .tracking(1)

                countBadge
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    store.acknowledgeAll()
                }
            } label: {
                Text("Dismiss All")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var countBadge: some View {
        let count = store.unacknowledged.count
        let color: Color = store.criticalCount > 0 ? .red : .orange

        return Text("\(count)")
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    // MARK: - Event List

    private var eventList: some View {
        ForEach(store.unacknowledged) { event in
            AttentionEventRow(event: event) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    store.acknowledge(event.id)
                }
            }

            if event.id != store.unacknowledged.last?.id {
                Divider().padding(.leading, 36)
            }
        }
    }
}

// MARK: - Attention Event Row

private struct AttentionEventRow: View {
    let event: AttentionEvent
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            severityIcon
            messageContent
            Spacer()
            dismissButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(severityTint)
    }

    // MARK: - Severity Icon

    private var severityIcon: some View {
        Image(systemName: iconName)
            .font(.subheadline)
            .foregroundStyle(iconColor)
            .frame(width: 20)
    }

    private var iconName: String {
        switch event.type {
        case .permissionNeeded: return "lock.fill"
        case .stuck:           return "exclamationmark.triangle.fill"
        case .errorLoop:       return "arrow.counterclockwise"
        case .completed:       return "checkmark.circle.fill"
        case .contextLow:      return "chart.bar.fill"
        case .conflict:        return "arrow.triangle.merge"
        case .reviewReady:     return "doc.text.magnifyingglass"
        }
    }

    private var iconColor: Color {
        switch event.severity {
        case .critical: return .red
        case .warning:  return .orange
        case .info:     return .green
        }
    }

    // MARK: - Message

    private var messageContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(typeLabel)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(iconColor)

            Text(event.message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)

            if let date = event.createdAt {
                Text(date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var typeLabel: String {
        switch event.type {
        case .permissionNeeded: return "Needs Approval"
        case .stuck:           return "Stuck"
        case .errorLoop:       return "Error Loop"
        case .completed:       return "Completed"
        case .contextLow:      return "Context Low"
        case .conflict:        return "File Conflict"
        case .reviewReady:     return "Ready for Review"
        }
    }

    // MARK: - Dismiss

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Background Tint

    private var severityTint: some View {
        switch event.severity {
        case .critical: return Color.red.opacity(0.08)
        case .warning:  return Color.orange.opacity(0.08)
        case .info:     return Color.green.opacity(0.08)
        }
    }
}

// MARK: - Preview

#Preview("With Events") {
    AttentionPanel(store: {
        let s = AttentionStore.shared
        return s
    }())
    .padding()
    .frame(width: 500)
}
