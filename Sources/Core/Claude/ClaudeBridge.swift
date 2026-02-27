import Foundation
import SwiftUI

/// Events yielded during a conversation turn — text streaming, tool activity, completion.
enum BridgeEvent {
    case text(String)
    case toolStart(name: String, input: String)
    case toolEnd(name: String, result: String, isError: Bool)
    case done(usage: SessionTokenUsage)
    case error(String)
}

/// Thin delegate that routes messages through ProviderManager or DaemonChannel.
///
/// Routing priority:
/// 1. DaemonChannel (HTTP SSE) — when daemon is connected and daemon routing enabled
/// 2. ProviderManager — direct LLM provider (fallback)
///
/// Maintains the same `send()` interface that BranchViewModel expects.
@MainActor
final class ClaudeBridge {
    /// Shared instance for callers (e.g. WorldTreeServer WS handler) that don't own a lifecycle.
    static let shared = ClaudeBridge()

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let contextLoader = ProjectContextLoader()

    @AppStorage(AppConstants.daemonChannelEnabledKey)
    private var daemonEnabled: Bool = true

    init() {
        wtLog("[ClaudeBridge] initialized, active provider: \(ProviderManager.shared.activeProviderName)")
    }

    var isRunning: Bool { ProviderManager.shared.isRunning }

    var hasAPIAccess: Bool {
        ProviderManager.shared.activeProvider != nil
    }

    /// Human-readable name of the active provider for UI display
    var activeProviderName: String {
        if daemonEnabled && DaemonService.shared.isConnected {
            return "Daemon (direct)"
        }
        return ProviderManager.shared.activeProviderName
    }

    // MARK: - Send

    /// Primary entry point — accepts a fully-constructed ProviderSendContext so
    /// attachments, recentContext, and other fields are preserved on the direct path.
    /// Daemon path forwards core fields; daemon handles its own context enrichment.
    func send(context: ProviderSendContext) -> AsyncStream<BridgeEvent> {
        if daemonEnabled && DaemonService.shared.isConnected {
            wtLog("[ClaudeBridge] routing to daemon, session=\(context.sessionId)")
            return wrapDaemonWithFallback(
                message: context.message,
                sessionId: context.sessionId,
                branchId: context.branchId,
                model: context.model,
                workingDirectory: context.workingDirectory,
                project: context.project,
                checkpointContext: context.checkpointContext,
                fullContext: context  // preserve full context for fallback
            )
        }

        wtLog("[ClaudeBridge] routing direct to \(ProviderManager.shared.activeProviderName), session=\(context.sessionId)")
        return ProviderManager.shared.send(context: context)
    }

    /// Legacy parameter-based entry point — used by WorldTreeServer and other callers
    /// that construct context inline.
    func send(
        message: String,
        sessionId: String,
        branchId: String,
        model: String?,
        workingDirectory: String?,
        project: String?,
        checkpointContext: String? = nil
    ) -> AsyncStream<BridgeEvent> {
        // Route through daemon if enabled AND daemon is reachable.
        // Skip daemon entirely when isConnected = false — no need to attempt
        // a connection that will fail and delay the direct-provider fallback.
        if daemonEnabled && DaemonService.shared.isConnected {
            wtLog("[ClaudeBridge] routing to daemon, session=\(sessionId)")
            return wrapDaemonWithFallback(
                message: message,
                sessionId: sessionId,
                branchId: branchId,
                model: model,
                workingDirectory: workingDirectory,
                project: project,
                checkpointContext: checkpointContext
            )
        }

        return sendDirect(
            message: message,
            sessionId: sessionId,
            branchId: branchId,
            model: model,
            workingDirectory: workingDirectory,
            project: project,
            checkpointContext: checkpointContext
        )
    }

    // MARK: - Daemon routing with fallback

    /// When `fullContext` is provided (primary send path), the fallback uses it directly
    /// so attachments, recentContext, parentSessionId, and other fields are preserved.
    /// Legacy callers (WorldTreeServer) omit `fullContext` and fall back via sendDirect().
    private func wrapDaemonWithFallback(
        message: String,
        sessionId: String,
        branchId: String,
        model: String?,
        workingDirectory: String?,
        project: String?,
        checkpointContext: String?,
        fullContext: ProviderSendContext? = nil
    ) -> AsyncStream<BridgeEvent> {
        AsyncStream { continuation in
            Task { @MainActor in
                var receivedContent = false
                let daemonStream = await DaemonChannel.shared.send(
                    text: message,
                    project: project,
                    branchId: branchId,
                    sessionId: sessionId
                )

                for await event in daemonStream {
                    switch event {
                    case .error where !receivedContent:
                        // Daemon reported an error before producing any text — fall through immediately.
                        wtLog("[ClaudeBridge] Daemon error before content — falling back to direct provider")
                        break
                    case .text:
                        // Only mark content received for actual text tokens.
                        receivedContent = true
                        continuation.yield(event)
                        continue
                    case .done where !receivedContent:
                        // Daemon stream ended with no text (silent empty run) — fall through below.
                        wtLog("[ClaudeBridge] Daemon produced no content — falling back to direct provider")
                        break
                    default:
                        continuation.yield(event)
                        continue
                    }
                    // An error or empty-done caused us to exit the loop — fall back below.
                    break
                }

                if !receivedContent {
                    // Daemon didn't produce text — route to direct provider, preserving full context.
                    wtLog("[ClaudeBridge] Falling back to direct provider for session=\(sessionId)")
                    let directStream: AsyncStream<BridgeEvent>
                    if let ctx = fullContext {
                        directStream = ProviderManager.shared.send(context: ctx)
                    } else {
                        directStream = self.sendDirect(
                            message: message,
                            sessionId: sessionId,
                            branchId: branchId,
                            model: model,
                            workingDirectory: workingDirectory,
                            project: project,
                            checkpointContext: checkpointContext
                        )
                    }
                    for await directEvent in directStream {
                        continuation.yield(directEvent)
                    }
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Direct provider routing

    private func sendDirect(
        message: String,
        sessionId: String,
        branchId: String,
        model: String?,
        workingDirectory: String?,
        project: String?,
        checkpointContext: String?
    ) -> AsyncStream<BridgeEvent> {
        // Resolve parent session for fork/resume inheritance
        let parentSessionId = resolveParentSessionId(branchId: branchId)
        let isNewSession = !hasExistingSession(sessionId: sessionId)

        let thinkingEnabled = UserDefaults.standard.bool(forKey: "extendedThinkingEnabled")
        let cwd = workingDirectory ?? resolveWorkingDirectory(nil, project: project)

        var context = ProviderSendContext(
            message: message,
            sessionId: sessionId,
            branchId: branchId,
            model: model,
            workingDirectory: cwd,
            project: project,
            parentSessionId: parentSessionId,
            isNewSession: isNewSession,
            extendedThinking: thinkingEnabled
        )
        context.checkpointContext = checkpointContext

        // Inject project context for CLI providers (AnthropicAPI does its own via ConversationStateManager)
        let projectContext = loadProjectContextSync(project: project, workingDirectory: cwd)
        if !projectContext.isEmpty {
            let existing = context.recentContext ?? ""
            context.recentContext = existing.isEmpty ? projectContext : "\(projectContext)\n\n\(existing)"
        }

        wtLog("[ClaudeBridge] routing to \(ProviderManager.shared.activeProviderName), session=\(sessionId), parent=\(parentSessionId ?? "none")")
        return ProviderManager.shared.send(context: context)
    }

    // MARK: - Programmatic Dispatch

    /// Fire-and-forget dispatch through the Agent SDK provider.
    /// Unlike send(), dispatches are isolated (no session state), tracked in canvas_dispatches,
    /// and visible in the Command Center.
    func dispatch(
        message: String,
        project: String,
        workingDirectory: String,
        model: String? = nil,
        branchId: String? = nil,
        origin: DispatchOrigin = .background,
        allowedTools: [String]? = nil,
        skipPermissions: Bool = true,
        systemPrompt: String? = nil
    ) -> AsyncStream<BridgeEvent> {
        // Inject project context into system prompt if no override provided
        let resolvedPrompt: String?
        if let systemPrompt {
            resolvedPrompt = systemPrompt
        } else {
            let projectCtx = loadProjectContextSync(project: project, workingDirectory: workingDirectory)
            resolvedPrompt = projectCtx.isEmpty ? nil : projectCtx
        }

        let context = DispatchContext(
            message: message,
            project: project,
            workingDirectory: workingDirectory,
            model: model,
            branchId: branchId,
            origin: origin,
            allowedTools: allowedTools,
            skipPermissions: skipPermissions,
            systemPromptOverride: resolvedPrompt
        )

        wtLog("[ClaudeBridge] dispatching to Agent SDK: project=\(project), origin=\(origin.rawValue)")
        let (_, stream) = DispatchRouter.dispatch(context: context)
        return stream
    }

    /// Cancel a specific background dispatch by ID
    func cancelDispatch(_ dispatchId: String) {
        DispatchRouter.cancelDispatch(dispatchId)
    }

    // MARK: - Cancel

    func cancel() {
        ProviderManager.shared.cancel()
    }

    // MARK: - Project Context

    /// Load project context synchronously from the cache.
    /// Uses cached data only (no git/filesystem calls) to avoid blocking the UI thread.
    /// ProjectContextLoader.loadContext() is async — use loadProjectContextAsync() for full context.
    private func loadProjectContextSync(project: String?, workingDirectory: String?) -> String {
        guard let cwd = workingDirectory else { return "" }
        let cache = ProjectCache()

        // Try by path first, then by name
        let cached: CachedProject?
        if let byPath = try? cache.get(path: cwd) {
            cached = byPath
        } else if let name = project, let byName = try? cache.getByName(name) {
            cached = byName
        } else {
            cached = nil
        }

        guard let project = cached else { return "" }

        // Build context from cached data only (no async git calls)
        var output = "# Project Context: \(project.name)\n"
        output += "**Type:** \(project.type.displayName)\n"
        output += "**Path:** `\(project.path)`\n"
        if let branch = project.gitBranch {
            output += "**Git Branch:** `\(branch)`"
            if project.gitDirty { output += " (uncommitted changes)" }
            output += "\n"
        }
        if let readme = project.readme, !readme.isEmpty {
            output += "\n## README\n\(readme)\n"
        }
        return output
    }

    // MARK: - Helpers

    /// Look up the parent branch's session ID for context inheritance
    private func resolveParentSessionId(branchId: String) -> String? {
        guard let branch = try? TreeStore.shared.getBranch(branchId),
              let parentBranchId = branch.parentBranchId,
              let parentBranch = try? TreeStore.shared.getBranch(parentBranchId) else {
            return nil
        }
        return parentBranch.sessionId
    }

    /// Check if a session already has messages (determines isNewSession)
    private func hasExistingSession(sessionId: String) -> Bool {
        MessageStore.shared.hasMessages(sessionId: sessionId)
    }

}
