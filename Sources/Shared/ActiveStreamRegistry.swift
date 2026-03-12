import Foundation

// MARK: - ActiveStreamRegistry

/// Singleton that owns the Task driving every live LLM stream.
///
/// The key problem this solves: SwiftUI deallocates DocumentEditorViewModel whenever the user
/// navigates away from a conversation. With the old design, the stream Task was stored on the
/// ViewModel — deallocation meant cancellation, and the in-progress response was lost.
///
/// With ActiveStreamRegistry:
/// - Tasks are owned by this singleton (independent of any ViewModel)
/// - Any number of ViewModels can subscribe/unsubscribe without affecting the stream
/// - When a new ViewModel loads for a branch with an active stream, it subscribes and
///   immediately catches up via `currentContent(for:)`
/// - On natural completion, the registry persists the response to DB and fires a notification
/// - On cancellation, the registry persists the partial response to DB
///
/// Thread safety: @MainActor — all mutations happen on the main thread, matching
/// ProcessingRegistry, GlobalStreamRegistry, and DocumentEditorViewModel.
@MainActor
final class ActiveStreamRegistry {
    static let shared = ActiveStreamRegistry()
    private init() {}

    // MARK: - Internal Handle

    private struct StreamHandle {
        let branchId: String
        let sessionId: String
        let treeId: String?
        let projectName: String?
        var accumulatedContent: String = ""
        var task: Task<Void, Never>
        /// Registered event subscribers — keyed by UUID cookie.
        var subscribers: [UUID: (BridgeEvent) -> Void] = [:]
    }

    // MARK: - State

    private var handles: [String: StreamHandle] = [:]

    // MARK: - Public API

    /// True when a stream Task is currently active for `branchId`.
    func isActive(_ branchId: String) -> Bool {
        handles[branchId] != nil
    }

    /// Returns the full accumulated content so far — used by a new ViewModel to
    /// catch up instantly when navigating back to a streaming branch.
    func currentContent(for branchId: String) -> String? {
        handles[branchId]?.accumulatedContent
    }

    /// Subscribe to events from an active stream.
    ///
    /// Returns a UUID cookie — pass it to `unsubscribe` when the ViewModel deallocates.
    /// Unsubscribing does NOT cancel the stream; the Task keeps running.
    func subscribe(branchId: String, onEvent: @escaping (BridgeEvent) -> Void) -> UUID {
        let id = UUID()
        handles[branchId]?.subscribers[id] = onEvent
        return id
    }

    /// Remove a subscriber. The stream continues unaffected.
    func unsubscribe(branchId: String, id: UUID) {
        handles[branchId]?.subscribers.removeValue(forKey: id)
    }

    /// Start a new stream Task owned by the registry.
    ///
    /// If a stream is already active for `branchId`, this is a no-op (log a warning).
    /// The caller is responsible for calling `cancelStream` first if preemption is needed.
    func startStream(
        branchId: String,
        sessionId: String,
        treeId: String?,
        projectName: String?,
        stream: AsyncStream<BridgeEvent>
    ) {
        if handles[branchId] != nil {
            wtLog("[ActiveStreamRegistry] startStream called while stream already active for \(branchId) — ignoring")
            return
        }

        // Placeholder task — replaced immediately below once we close over the handle key
        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            WakeLock.shared.acquire()
            ProcessingRegistry.shared.register(branchId)
            GlobalStreamRegistry.shared.beginStream(
                branchId: branchId,
                sessionId: sessionId,
                treeId: treeId,
                projectName: projectName
            )

            for await event in stream {
                guard !Task.isCancelled else { break }

                // Accumulate text content in the handle
                if case .text(let token) = event {
                    self.handles[branchId]?.accumulatedContent += token
                    // Mirror tail to GlobalStreamRegistry for Command Center / sidebar previews
                    let full = self.handles[branchId]?.accumulatedContent ?? ""
                    GlobalStreamRegistry.shared.appendContent(branchId: branchId, content: full)
                    // Crash-recovery write — fire-and-forget
                    Task { await StreamCacheManager.shared.appendToStream(sessionId: sessionId, chunk: token) }
                }

                // Forward to all current subscribers
                if let subs = self.handles[branchId]?.subscribers {
                    for callback in subs.values {
                        callback(event)
                    }
                }

                // Break on terminal events
                switch event {
                case .done, .error:
                    break
                default:
                    continue
                }
                break
            }

            // --- Post-stream cleanup ---
            let wasCancelled = Task.isCancelled
            let accumulated = self.handles[branchId]?.accumulatedContent ?? ""

            if !wasCancelled && !accumulated.isEmpty {
                // Persist the completed response
                _ = try? MessageStore.shared.sendMessage(
                    sessionId: sessionId, role: .assistant, content: accumulated)
                if let branch = try? TreeStore.shared.getBranchBySessionId(sessionId) {
                    try? TreeStore.shared.updateTreeTimestamp(branch.treeId)
                }
            }

            GlobalStreamRegistry.shared.endStream(branchId: branchId, notify: !wasCancelled)
            ProcessingRegistry.shared.deregister(branchId)
            WakeLock.shared.release()

            await StreamCacheManager.shared.closeStream(sessionId: sessionId)

            NotificationCenter.default.post(
                name: .activeStreamComplete,
                object: nil,
                userInfo: ["branchId": branchId, "sessionId": sessionId]
            )

            self.handles.removeValue(forKey: branchId)
        }

        handles[branchId] = StreamHandle(
            branchId: branchId,
            sessionId: sessionId,
            treeId: treeId,
            projectName: projectName,
            task: task
        )
    }

    /// Cancel the active stream for `branchId` and persist any partial content.
    ///
    /// UI teardown (streamingContent, stopStreamBatching, etc.) is the caller's responsibility.
    func cancelStream(branchId: String) {
        guard let handle = handles[branchId] else { return }

        let partial = handle.accumulatedContent
        let sessionId = handle.sessionId

        handle.task.cancel()

        // Persist partial response synchronously before removing the handle
        if !partial.isEmpty {
            _ = try? MessageStore.shared.sendMessage(
                sessionId: sessionId, role: .assistant, content: partial)
            if let branch = try? TreeStore.shared.getBranchBySessionId(sessionId) {
                try? TreeStore.shared.updateTreeTimestamp(branch.treeId)
            }
        }

        GlobalStreamRegistry.shared.endStream(branchId: branchId, notify: false)
        ProcessingRegistry.shared.deregister(branchId)
        WakeLock.shared.release()

        handles.removeValue(forKey: branchId)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when an ActiveStreamRegistry-owned stream completes naturally (done or error).
    /// userInfo: ["branchId": String, "sessionId": String]
    static let activeStreamComplete = Notification.Name("activeStreamComplete")
}
