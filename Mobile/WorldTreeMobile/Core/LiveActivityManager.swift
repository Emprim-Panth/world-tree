import Foundation
import ActivityKit

// MARK: - LiveActivityManager (TASK-058)
//
// Manages the lifecycle of a World Tree Live Activity that surfaces
// Cortana's streaming response on the Lock Screen and Dynamic Island.
//
// Usage:
//   LiveActivityManager.shared.startActivity(treeName:branchName:)  — call just before sending a message
//   LiveActivityManager.shared.updateActivity(text:)                — call on each token batch
//   LiveActivityManager.shared.endActivity()                        — call on message_complete
//
// Guard: Live Activities are only available on iOS 16.2+.
// ActivityKit requires NSSupportsLiveActivities = YES in Info.plist (set in project.yml).

@MainActor
final class LiveActivityManager {

    static let shared = LiveActivityManager()
    private init() {}

    // MARK: - State

    @available(iOS 16.2, *)
    private var activity: Activity<WorldTreeActivityAttributes>?

    // Batch token updates to avoid hammering ActivityKit with every single character.
    // Sends an update at most once per 0.5 seconds.
    private var pendingText: String = ""
    private var updateScheduled: Bool = false

    // MARK: - Public API

    /// Start a Live Activity for a new Cortana response.
    /// Safe to call multiple times — ends any existing activity first.
    func startActivity(treeName: String, branchName: String?) {
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Clean up any stale activity from a previous message.
        endActivity()

        let attributes = WorldTreeActivityAttributes(treeName: treeName, branchName: branchName)
        let initialState = WorldTreeActivityAttributes.ContentState(
            streamingText: "",
            isStreaming: true
        )
        let content = ActivityContent(state: initialState, staleDate: Date().addingTimeInterval(300))

        do {
            activity = try Activity.request(attributes: attributes, content: content)
        } catch {
            // Non-fatal — app works fine without it.
            // Common failure: simulator, or user has disabled Live Activities for this app.
        }
    }

    /// Accumulate a new token and schedule a batched update.
    func appendToken(_ token: String) {
        guard #available(iOS 16.2, *), activity != nil else { return }
        pendingText += token

        if !updateScheduled {
            updateScheduled = true
            Task { [weak self] in
                // Coalesce updates: wait 0.5s before pushing to ActivityKit.
                try? await Task.sleep(for: .milliseconds(500))
                await self?.flushUpdate()
            }
        }
    }

    /// Force-flush the current pending text as an ActivityKit update.
    func endActivity() {
        guard #available(iOS 16.2, *) else { return }

        if let activity {
            let finalState = WorldTreeActivityAttributes.ContentState(
                streamingText: pendingText.isEmpty ? "Response complete." : String(pendingText.prefix(200)),
                isStreaming: false
            )
            let content = ActivityContent(state: finalState, staleDate: nil)
            Task {
                await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(8)))
            }
        }

        activity = nil
        pendingText = ""
        updateScheduled = false
    }

    // MARK: - Private

    @available(iOS 16.2, *)
    private func flushUpdate() async {
        updateScheduled = false
        guard let activity else { return }

        let state = WorldTreeActivityAttributes.ContentState(
            streamingText: String(pendingText.suffix(200)), // show most recent 200 chars
            isStreaming: true
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(300))
        await activity.update(content)
    }
}
