import Foundation

// MARK: - TokenBroadcaster

/// Converts BridgeEvent streams into WebSocket frames and broadcasts to subscribed clients.
///
/// Both the SSE handler (WorldTreeServer) and the WebSocket `send_message` handler route
/// through TokenBroadcaster so all WebSocket clients subscribed to a branch receive
/// token/tool_status/message_complete frames in real time.
///
/// One broadcast Task runs per active LLM stream (keyed by branchId). Calling `broadcast`
/// while a stream is already active on that branch cancels the previous one.
@MainActor
final class TokenBroadcaster {
    static let shared = TokenBroadcaster()

    /// Per-branch token index. Reset at stream start, removed on completion/error.
    var tokenIndexes: [String: Int] = [:]

    /// Active broadcast tasks — allows cancellation via `cancel(branchId:)`.
    private var activeTasks: [String: Task<Void, Never>] = [:]

    /// Per-branch accumulated text — kept in sync so `cancel(branchId:)` can persist partial responses.
    private var accumulatedText: [String: String] = [:]

    /// Per-branch sessionId — needed by `cancel(branchId:)` to persist and identify the message.
    private var sessionIds: [String: String] = [:]

    private init() {}

    // MARK: - Broadcast

    /// Subscribe to `stream` and broadcast every event as a WebSocket frame to all
    /// clients currently subscribed to `branchId`.
    ///
    /// - Returns: The Task driving the broadcast (discardable).
    @discardableResult
    func broadcast(
        stream: AsyncStream<BridgeEvent>,
        branchId: String,
        sessionId: String
    ) -> Task<Void, Never> {
        // Cancel any prior stream on this branch (preemption — no partial persist)
        activeTasks[branchId]?.cancel()
        activeTasks.removeValue(forKey: branchId)
        tokenIndexes.removeValue(forKey: branchId)
        accumulatedText.removeValue(forKey: branchId)
        sessionIds.removeValue(forKey: branchId)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            self.tokenIndexes[branchId] = 0
            self.accumulatedText[branchId] = ""
            self.sessionIds[branchId] = sessionId
            var accumulated = ""

            for await event in stream {
                guard !Task.isCancelled else { break }

                let frame = self.convert(
                    event: event,
                    branchId: branchId,
                    sessionId: sessionId,
                    accumulated: &accumulated
                )

                // Keep shared state in sync so cancel() can read the latest partial text
                self.accumulatedText[branchId] = accumulated

                if let frame {
                    WorldTreeServer.shared.broadcastToSubscribers(branchId: branchId, message: frame)
                }

                // Terminal events — stop consuming the stream
                switch event {
                case .done, .error: break
                default: continue
                }
                break
            }

            self.tokenIndexes.removeValue(forKey: branchId)
            self.activeTasks.removeValue(forKey: branchId)
            self.accumulatedText.removeValue(forKey: branchId)
            self.sessionIds.removeValue(forKey: branchId)
        }

        activeTasks[branchId] = task
        return task
    }

    /// Cancel an active broadcast (e.g. from a `cancel_stream` WebSocket message).
    /// Persists any accumulated partial response and broadcasts `message_complete` to subscribers.
    func cancel(branchId: String) {
        let partial = accumulatedText[branchId] ?? ""
        let sessionId = sessionIds[branchId]

        activeTasks[branchId]?.cancel()
        activeTasks.removeValue(forKey: branchId)
        tokenIndexes.removeValue(forKey: branchId)
        accumulatedText.removeValue(forKey: branchId)
        sessionIds.removeValue(forKey: branchId)

        guard !partial.isEmpty, let sessionId else { return }

        // Persist the partial assistant message
        let savedId: String
        if let msg = try? MessageStore.shared.sendMessage(
            sessionId: sessionId, role: .assistant, content: partial
        ) {
            savedId = msg.id
            if let branch = try? TreeStore.shared.getBranchBySessionId(sessionId) {
                try? TreeStore.shared.updateTreeTimestamp(branch.treeId)
            }
        } else {
            savedId = UUID().uuidString
        }

        let tokenCount = max(1, partial.count / 4)
        let completeMsg = WSMessage.messageComplete(
            branchId: branchId,
            sessionId: sessionId,
            messageId: savedId,
            role: "assistant",
            content: partial,
            tokenCount: tokenCount
        )
        WorldTreeServer.shared.broadcastToSubscribers(branchId: branchId, message: completeMsg)
    }

    // MARK: - Event → Frame Conversion

    /// Convert a single BridgeEvent into a WSMessage frame.
    ///
    /// `accumulated` is updated in place for `.text` events and read for `.done`
    /// to build the `message_complete` payload. Returns `nil` for events that
    /// require no WebSocket frame.
    func convert(
        event: BridgeEvent,
        branchId: String,
        sessionId: String,
        accumulated: inout String
    ) -> WSMessage? {
        switch event {

        case .text(let token):
            let index = tokenIndexes[branchId, default: 0]
            tokenIndexes[branchId] = index + 1
            accumulated += token
            return .token(
                branchId: branchId,
                sessionId: sessionId,
                token: token,
                index: index
            )

        case .toolStart(let name, _):
            return .toolStatus(branchId: branchId, tool: name, status: "started")

        case .toolEnd(let name, _, let isError):
            return .toolStatus(
                branchId: branchId,
                tool: name,
                status: isError ? "error" : "completed"
            )

        case .done(let usage):
            // Record token usage to canvas_token_usage + project metrics
            if usage.totalInputTokens > 0 || usage.totalOutputTokens > 0 {
                let resolvedModel = UserDefaults.standard.string(forKey: "defaultModel") ?? AppConstants.defaultModel
                TokenTracker.shared.record(
                    sessionId: sessionId,
                    branchId: branchId,
                    inputTokens: usage.totalInputTokens,
                    outputTokens: usage.totalOutputTokens,
                    cacheHitTokens: usage.cacheHitTokens,
                    model: resolvedModel
                )
            }

            // Persist assistant message; fall back to a generated id on failure
            let savedId: String
            if let msg = try? MessageStore.shared.sendMessage(
                sessionId: sessionId, role: .assistant, content: accumulated
            ) {
                savedId = msg.id
                // Bump tree timestamp so the sidebar refreshes
                if let branch = try? TreeStore.shared.getBranchBySessionId(sessionId) {
                    try? TreeStore.shared.updateTreeTimestamp(branch.treeId)
                }
            } else {
                savedId = UUID().uuidString
            }

            // Use output tokens when available; estimate from content length otherwise
            let tokenCount = usage.totalOutputTokens > 0
                ? usage.totalOutputTokens
                : max(1, accumulated.count / 4)

            return .messageComplete(
                branchId: branchId,
                sessionId: sessionId,
                messageId: savedId,
                role: "assistant",
                content: accumulated,
                tokenCount: tokenCount
            )

        case .error(let msg):
            return .error(code: "llm_error", message: msg)
        }
    }
}
