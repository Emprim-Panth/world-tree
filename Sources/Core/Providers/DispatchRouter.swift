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
    static func dispatch(
        context: DispatchContext
    ) -> (id: String, stream: AsyncStream<BridgeEvent>) {
        let provider = sdkProvider
        return provider.dispatch(context: context)
    }

    /// Cancel a specific dispatch by ID
    static func cancelDispatch(_ dispatchId: String) {
        sdkProvider.cancelDispatch(dispatchId)
    }

    /// Check active dispatches
    static var activeDispatchCount: Int {
        sdkProvider.activeDispatchIds.count
    }

    // MARK: - Provider Access

    /// Resolves the Agent SDK provider from ProviderManager.
    /// Always goes through ProviderManager to guarantee a single shared instance.
    private static var sdkProvider: AgentSDKProvider {
        guard let provider = ProviderManager.shared.provider(withId: "agent-sdk") as? AgentSDKProvider else {
            fatalError("[DispatchRouter] AgentSDKProvider not registered in ProviderManager")
        }
        return provider
    }
}
