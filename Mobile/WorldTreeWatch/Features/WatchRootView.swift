import SwiftUI

// MARK: - Watch Root View (TASK-065)

struct WatchRootView: View {
    @EnvironmentObject var store: WatchStore

    var body: some View {
        NavigationStack {
            WatchConversationView()
                .navigationTitle("Cortana")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Main Conversation View

struct WatchConversationView: View {
    @EnvironmentObject var store: WatchStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // Context pill
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(.indigo)
                    Text(contextLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())

                // Response content
                if store.isStreaming {
                    StreamingResponseView(text: store.streamingText)
                } else if !store.lastMessage.isEmpty {
                    LastResponseView(text: store.lastMessage)
                } else {
                    EmptyStateView()
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var contextLabel: String {
        if let branch = store.branchName, !branch.isEmpty, branch.lowercased() != "main" {
            return "\(store.treeName) › \(branch)"
        }
        return store.treeName
    }
}

// MARK: - Streaming Response

private struct StreamingResponseView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Responding…")
                    .font(.caption2)
                    .foregroundStyle(.indigo)
            }

            if !text.isEmpty {
                Text(text.suffix(300))  // show the latest 300 chars on the small display
                    .font(.body)
                    .lineLimit(8)
            }
        }
    }
}

// MARK: - Last Response

private struct LastResponseView: View {
    let text: String

    var body: some View {
        Text(text.suffix(500))
            .font(.body)
            .lineLimit(12)
    }
}

// MARK: - Empty State

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.indigo)
            Text("Open World Tree on your iPhone to start a conversation.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .frame(maxWidth: .infinity)
    }
}
