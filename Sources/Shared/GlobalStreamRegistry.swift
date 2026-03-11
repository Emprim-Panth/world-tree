import Foundation
import Observation

/// Registry of live in-progress LLM streams, observable by any view in the app.
///
/// When a user navigates away from a streaming conversation, the DocumentEditorViewModel
/// is deallocated by SwiftUI, but the underlying stream Task keeps running (strong self-capture).
/// This registry captures accumulated content from that Task so:
///
/// 1. A **new ViewModel** created on navigate-back can restore the in-progress response
///    immediately — no blank bubble, no lost tokens.
/// 2. The **Command Center LiveStreamsSection** can show cross-branch streaming activity
///    at a glance without requiring the user to be in any specific conversation.
///
/// Thread safety: `@MainActor` ensures all mutations happen on the main thread, matching
/// `ProcessingRegistry` and `DocumentEditorViewModel` which are also main-actor-bound.
@MainActor
@Observable
final class GlobalStreamRegistry {
    static let shared = GlobalStreamRegistry()
    private init() {}

    // MARK: - Model

    struct StreamEntry: Identifiable {
        /// branchId — unique key, one entry per active stream
        let id: String
        let sessionId: String
        let treeId: String?
        let projectName: String?
        let startedAt: Date
        /// Rolling tail of the accumulated response (last 600 chars).
        /// Bounded to prevent unbounded memory growth during long responses.
        var latestContent: String
        var currentTool: String?
    }

    // MARK: - State

    private(set) var streams: [String: StreamEntry] = [:]

    var activeStreams: [StreamEntry] {
        streams.values.sorted { $0.startedAt < $1.startedAt }
    }

    var hasActiveStreams: Bool { !streams.isEmpty }

    // MARK: - Mutations

    /// Called when streaming begins for a branch. Replaces any prior entry for that branch.
    func beginStream(branchId: String, sessionId: String, treeId: String?, projectName: String?) {
        streams[branchId] = StreamEntry(
            id: branchId,
            sessionId: sessionId,
            treeId: treeId,
            projectName: projectName,
            startedAt: Date(),
            latestContent: "",
            currentTool: nil
        )
    }

    /// Mirror the full accumulated `streamingContent` value — caller passes the complete
    /// accumulated string (not a delta). We keep the last 600 chars as a preview tail.
    func appendContent(branchId: String, content: String) {
        guard streams[branchId] != nil else { return }
        streams[branchId]?.latestContent = String(content.suffix(600))
    }

    /// Update the current tool name (nil when no tool is active).
    func updateTool(branchId: String, tool: String?) {
        streams[branchId]?.currentTool = tool
    }

    /// Called when the stream completes or is cancelled. Removes the entry.
    /// Pass `notify: false` when cancelling — only send a notification for natural completions.
    /// Idempotent — safe to call multiple times for the same branch.
    func endStream(branchId: String, notify: Bool = true) {
        guard let entry = streams.removeValue(forKey: branchId) else { return }
        guard notify else { return }
        let projectName = entry.projectName
        Task {
            await NotificationManager.shared.notify(
                title: "Cortana finished responding",
                body: projectName.map { "Ready for your input in \($0)." } ?? "Ready for your input."
            )
        }
    }

    /// Returns the current accumulated content for a branch — used by a new ViewModel
    /// to restore the in-progress stream display immediately on navigate-back.
    func currentContent(for branchId: String) -> String? {
        streams[branchId]?.latestContent
    }

    /// Returns the full stream entry for a branch, or nil if not streaming.
    /// Used by sidebar to show live thinking previews.
    func streamEntry(for branchId: String) -> StreamEntry? {
        streams[branchId]
    }
}
