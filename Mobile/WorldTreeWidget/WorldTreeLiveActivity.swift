import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Live Activity Attributes (TASK-058)
//
// Represents an in-progress Cortana streaming response.
// Static info: tree + branch names (don't change during the response).
// ContentState: streaming text + elapsed time (update on every token batch).

struct WorldTreeActivityAttributes: ActivityAttributes {

    // MARK: - Static Context (set once on request)

    let treeName: String
    let branchName: String?

    // MARK: - Dynamic State (updated while streaming)

    struct ContentState: Codable, Hashable {
        /// Truncated preview of the streaming response (max 200 chars for readability).
        var streamingText: String
        /// Whether Cortana is still typing (false = response complete).
        var isStreaming: Bool
    }
}

// MARK: - Live Activity Widget Configuration

struct WorldTreeLiveActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorldTreeActivityAttributes.self) { context in
            // Lock Screen / Notification Center presentation
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded (long-press) presentation
                DynamicIslandExpandedRegion(.leading) {
                    Label("World Tree", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isStreaming {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.streamingText.isEmpty ? "Thinking…" : context.state.streamingText)
                        .font(.footnote)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "bubble.left.fill")
                    .foregroundStyle(.indigo)
                    .font(.caption)
            } compactTrailing: {
                if context.state.isStreaming {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            } minimal: {
                Image(systemName: context.state.isStreaming ? "ellipsis" : "checkmark")
                    .foregroundStyle(context.state.isStreaming ? .indigo : .green)
                    .font(.caption2)
            }
        }
    }
}

// MARK: - Lock Screen Presentation

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<WorldTreeActivityAttributes>

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Left: icon + spinner/done indicator
            ZStack {
                Circle()
                    .fill(Color.indigo.gradient)
                    .frame(width: 36, height: 36)
                if context.state.isStreaming {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.white)
                } else {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(context.attributes.treeName)
                        .font(.caption.weight(.semibold))
                    if let branch = context.attributes.branchName,
                       !branch.isEmpty,
                       branch.lowercased() != "main" {
                        Text("›")
                            .foregroundStyle(.secondary)
                        Text(branch)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(context.state.isStreaming ? "Responding…" : "Done")
                        .font(.caption2)
                        .foregroundStyle(context.state.isStreaming ? .indigo : .green)
                }

                Text(context.state.streamingText.isEmpty ? "Cortana is thinking…" : context.state.streamingText)
                    .font(.footnote)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .activityBackgroundTint(Color(.systemBackground))
    }
}
