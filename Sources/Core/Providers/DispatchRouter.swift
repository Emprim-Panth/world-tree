import Foundation

// MARK: - Dispatch Router

/// Routes dispatch requests to the appropriate provider based on task type and origin.
///
/// Routing rules:
/// - Conversation messages (user typing) → ClaudeCodeProvider (interactive, unchanged)
/// - Background tasks from Command Center → AgentSDKProvider (programmatic)
/// - Gateway dispatch requests → AgentSDKProvider (programmatic)
/// - Crew delegation → AgentSDKProvider (programmatic)
/// - User explicit choice → whatever they picked
@MainActor
enum DispatchRouter {

    /// Fire a programmatic dispatch through the Agent SDK provider.
    /// Returns a stream of BridgeEvents and the dispatch ID for tracking.
    /// Returns nil with an error event if the provider is unavailable.
    static func dispatch(
        context: DispatchContext
    ) -> (id: String, stream: AsyncStream<BridgeEvent>) {
        guard let provider = resolveProvider() else {
            let errorId = UUID().uuidString
            let stream = AsyncStream<BridgeEvent> { continuation in
                continuation.yield(.error("[DispatchRouter] AgentSDKProvider not available — check ProviderManager registration"))
                continuation.finish()
            }
            return (id: errorId, stream: stream)
        }
        return provider.dispatch(context: context)
    }

    /// Cancel a specific dispatch by ID
    static func cancelDispatch(_ dispatchId: String) {
        resolveProvider()?.cancelDispatch(dispatchId)
    }

    /// Check active dispatches
    static var activeDispatchCount: Int {
        resolveProvider()?.activeDispatchIds.count ?? 0
    }

    // MARK: - Provider Access

    /// Resolves the Agent SDK provider from ProviderManager.
    /// Returns nil if the provider isn't registered (no crash).
    private static func resolveProvider() -> AgentSDKProvider? {
        guard let provider = ProviderManager.shared.provider(withId: "agent-sdk") as? AgentSDKProvider else {
            wtLog("[DispatchRouter] AgentSDKProvider not registered in ProviderManager")
            return nil
        }
        return provider
    }
}
