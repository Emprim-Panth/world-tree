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
/// Thread safety: handle state lives on MainActor, but stream consumption itself runs off the
/// UI actor so background/occluded windows don't stall token delivery or tool progress.
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
        let initialContent: String
        var accumulatedContent: String = ""
        var receivedText = false
        /// Last error message received — used by finishStream to surface the reason
        /// in the persisted failure notice instead of the generic "no response" fallback.
        var lastErrorMessage: String? = nil
        var task: Task<Void, Never>
        /// Registered event subscribers — keyed by UUID cookie.
        var subscribers: [UUID: (BridgeEvent) -> Void] = [:]
    }

    /// Hard timeout per stream — cancels and surfaces an error if a stream is still active
    /// after this interval. Catches hung CLI processes that never send .done or .error.
    private static let streamTimeoutInterval: TimeInterval = 15 * 60  // 15 minutes

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
    /// Returns `nil` if no stream handle exists for `branchId` (caller should retry after
    /// `.activeStreamStarted` fires).
    /// Unsubscribing does NOT cancel the stream; the Task keeps running.
    func subscribe(branchId: String, onEvent: @escaping (BridgeEvent) -> Void) -> UUID? {
        guard var handle = handles[branchId] else {
            wtLog("[ActiveStreamRegistry] subscribe called for \(branchId.prefix(8)) but no active handle — returning nil")
            return nil
        }
        let id = UUID()
        handle.subscribers[id] = onEvent
        handles[branchId] = handle
        return id
    }

    /// Remove a subscriber. The stream continues unaffected.
    func unsubscribe(branchId: String, id: UUID) {
        guard var handle = handles[branchId] else { return }
        handle.subscribers.removeValue(forKey: id)
        handles[branchId] = handle
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
        initialContent: String = "",
        stream: AsyncStream<BridgeEvent>,
        onEvent: ((BridgeEvent) -> Void)? = nil
    ) -> UUID? {
        if handles[branchId] != nil {
            forceRemoveHandle(branchId: branchId)
        }

        let subscriberId = onEvent.map { _ in UUID() }

        // Consume the provider stream off the UI actor. MainActor hops are limited to registry
        // bookkeeping and subscriber delivery, so the stream keeps moving even when the window
        // is not frontmost.
        let task = Task.detached(priority: .userInitiated) {
            await Self.consumeStream(
                branchId: branchId,
                sessionId: sessionId,
                treeId: treeId,
                projectName: projectName,
                stream: stream
            )
        }

        handles[branchId] = StreamHandle(
            branchId: branchId,
            sessionId: sessionId,
            treeId: treeId,
            projectName: projectName,
            initialContent: initialContent,
            accumulatedContent: initialContent,
            task: task,
            subscribers: {
                guard let subscriberId, let onEvent else { return [:] }
                return [subscriberId: onEvent]
            }()
        )

        if !initialContent.isEmpty {
            GlobalStreamRegistry.shared.appendContent(branchId: branchId, content: initialContent)
            Task { await StreamCacheManager.shared.appendToStream(sessionId: sessionId, chunk: initialContent) }
        }

        // Watchdog: cancel and surface an error if the stream hasn't completed after the timeout.
        // Guards against hung CLI processes that never send .done or .error.
        // IMPORTANT: do NOT use try? here — if the Task is cancelled (view teardown, etc.)
        // try? swallows CancellationError and the guard below fires immediately, producing
        // a false "stalled" error long before the real timeout has elapsed.
        let timeoutInterval = Self.streamTimeoutInterval
        Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(timeoutInterval)) } catch { return }
            guard let self, self.handles[branchId] != nil else { return }
            wtLog("[ActiveStreamRegistry] ⚠️ Stream timeout for \(branchId.prefix(8)) after \(Int(timeoutInterval / 60))min — force-cancelling")
            let timeoutMinutes = Int(timeoutInterval / 60)
            // Deliver error to all current subscribers before cancelling
            if let subs = self.handles[branchId]?.subscribers {
                for callback in subs.values {
                    callback(.error("No response after \(timeoutMinutes) minutes — the session may have stalled. Send another message to retry."))
                }
            }
            self.cancelStream(branchId: branchId)
        }

        return subscriberId
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
        if Self.shouldPersistAccumulatedContent(
            accumulatedContent: partial,
            initialContent: handle.initialContent,
            receivedText: handle.receivedText
        ) {
            persistAssistantContent(sessionId: sessionId, content: partial, phase: "cancel")
        }

        GlobalStreamRegistry.shared.endStream(branchId: branchId, notify: false)
        ProcessingRegistry.shared.deregister(branchId)
        WakeLock.shared.release()
        Task { await StreamCacheManager.shared.closeStream(sessionId: sessionId) }

        handles.removeValue(forKey: branchId)
    }

    // MARK: - Internal Helpers

    private func forceRemoveHandle(branchId: String) {
        // Previous handle hasn't cleaned up yet — force-remove it now.
        // cancelStream() should have been called first, but if the timing raced,
        // we must not silently drop the new stream.
        wtLog("[ActiveStreamRegistry] startStream called while handle exists for \(branchId) — force-removing stale handle")
        let staleHandle = handles[branchId]!
        staleHandle.task.cancel()
        GlobalStreamRegistry.shared.endStream(branchId: branchId, notify: false)
        ProcessingRegistry.shared.deregister(branchId)
        WakeLock.shared.release()
        handles.removeValue(forKey: branchId)
    }

    private func beginStream(
        branchId: String,
        sessionId: String,
        treeId: String?,
        projectName: String?
    ) {
        WakeLock.shared.acquire()
        ProcessingRegistry.shared.register(branchId)
        GlobalStreamRegistry.shared.beginStream(
            branchId: branchId,
            sessionId: sessionId,
            treeId: treeId,
            projectName: projectName
        )
        NotificationCenter.default.post(
            name: .activeStreamStarted,
            object: nil,
            userInfo: ["branchId": branchId, "sessionId": sessionId]
        )
    }

    private func process(event: BridgeEvent, branchId: String, sessionId: String) {
        switch event {
        case .text(let token):
            handles[branchId]?.accumulatedContent += token
            handles[branchId]?.receivedText = true
            let full = handles[branchId]?.accumulatedContent ?? ""
            if StreamRecoveryStore.shared.hasPendingRecovery(sessionId: sessionId) {
                StreamRecoveryStore.shared.updatePartialContent(sessionId: sessionId, partialContent: full)
            }
            GlobalStreamRegistry.shared.appendContent(branchId: branchId, content: full)
            Task { await StreamCacheManager.shared.appendToStream(sessionId: sessionId, chunk: token) }

        case .error(let msg):
            // Store the error reason so finishStream can surface it in the persisted
            // failure notice instead of the generic "no response" fallback.
            handles[branchId]?.lastErrorMessage = msg
            Task { await StreamCacheManager.shared.touchStream(sessionId: sessionId) }

        default:
            // Tool-only or thinking-only runs can be legitimately quiet for minutes.
            // Keep the recovery handle fresh so background work doesn't look orphaned.
            Task { await StreamCacheManager.shared.touchStream(sessionId: sessionId) }
        }

        if let subs = handles[branchId]?.subscribers {
            for callback in subs.values {
                callback(event)
            }
        }
    }

    private func persistAssistantContent(sessionId: String, content: String, phase: String) {
        do {
            _ = try MessageStore.shared.sendMessage(
                sessionId: sessionId,
                role: .assistant,
                content: content
            )
        } catch {
            wtLog("[ActiveStreamRegistry] Failed to persist assistant response during \(phase) for session \(sessionId.prefix(8)): \(error)")
            return
        }

        do {
            guard let branch = try TreeStore.shared.getBranchBySessionId(sessionId) else {
                wtLog("[ActiveStreamRegistry] No branch found while updating tree timestamp during \(phase) for session \(sessionId.prefix(8))")
                return
            }
            try TreeStore.shared.updateTreeTimestamp(branch.treeId)
        } catch {
            wtLog("[ActiveStreamRegistry] Failed to update tree timestamp during \(phase) for session \(sessionId.prefix(8)): \(error)")
        }
    }

    private func finishStream(branchId: String, sessionId: String) async {
        let accumulated = handles[branchId]?.accumulatedContent ?? ""
        let initialContent = handles[branchId]?.initialContent ?? ""
        let receivedText = handles[branchId]?.receivedText ?? false
        let lastError = handles[branchId]?.lastErrorMessage

        if Self.shouldPersistAccumulatedContent(
            accumulatedContent: accumulated,
            initialContent: initialContent,
            receivedText: receivedText
        ) {
            persistAssistantContent(sessionId: sessionId, content: accumulated, phase: "completion")
        } else if accumulated.isEmpty && initialContent.isEmpty && lastError == nil {
            // Stream ended with zero text and no error event — CLI/provider failed silently.
            // When lastError != nil, the ViewModel's .error handler already persisted
            // an inline error message, so we skip the duplicate notice here.
            wtLog("[ActiveStreamRegistry] Stream completed with no content for session \(sessionId.prefix(8)) — persisting failure notice")
            persistAssistantContent(
                sessionId: sessionId,
                content: "⚠️ No response received — the session may have expired. Send another message to continue.",
                phase: "empty-completion"
            )
        }

        GlobalStreamRegistry.shared.endStream(branchId: branchId, notify: true)
        ProcessingRegistry.shared.deregister(branchId)
        WakeLock.shared.release()

        await StreamCacheManager.shared.closeStream(sessionId: sessionId)

        NotificationCenter.default.post(
            name: .activeStreamComplete,
            object: nil,
            userInfo: ["branchId": branchId, "sessionId": sessionId]
        )

        handles.removeValue(forKey: branchId)
    }

    private nonisolated static func consumeStream(
        branchId: String,
        sessionId: String,
        treeId: String?,
        projectName: String?,
        stream: AsyncStream<BridgeEvent>
    ) async {
        await ActiveStreamRegistry.shared.beginStream(
            branchId: branchId,
            sessionId: sessionId,
            treeId: treeId,
            projectName: projectName
        )

        for await event in stream {
            guard !Task.isCancelled else { break }
            await ActiveStreamRegistry.shared.process(
                event: event,
                branchId: branchId,
                sessionId: sessionId
            )

            switch event {
            case .done, .error:
                break
            default:
                continue
            }
            break
        }

        guard !Task.isCancelled else { return }
        await ActiveStreamRegistry.shared.finishStream(branchId: branchId, sessionId: sessionId)
    }

    static func shouldPersistAccumulatedContent(
        accumulatedContent: String,
        initialContent: String,
        receivedText: Bool
    ) -> Bool {
        guard !accumulatedContent.isEmpty else { return false }
        guard !initialContent.isEmpty else { return true }
        return receivedText
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when an ActiveStreamRegistry-owned stream begins.
    /// userInfo: ["branchId": String, "sessionId": String]
    static let activeStreamStarted = Notification.Name("activeStreamStarted")

    /// Posted when an ActiveStreamRegistry-owned stream completes naturally (done or error).
    /// userInfo: ["branchId": String, "sessionId": String]
    static let activeStreamComplete = Notification.Name("activeStreamComplete")

    /// Posted by AppState.selectBranch() before switching to a different branch.
    /// userInfo: ["oldBranchId": String, "newBranchId": String]
    static let branchWillSwitch = Notification.Name("branchWillSwitch")
}
