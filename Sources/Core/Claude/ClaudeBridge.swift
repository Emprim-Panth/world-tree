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

/// Thin delegate that routes messages through ProviderManager or FridayChannel.
///
/// Routing priority:
/// 1. FridayChannel (daemon HTTP SSE) — when daemon is connected and Friday routing enabled
/// 2. ProviderManager — direct LLM provider (fallback)
///
/// Maintains the same `send()` interface that BranchViewModel expects.
@MainActor
final class ClaudeBridge {
    /// Shared instance for callers (e.g. CanvasServer WS handler) that don't own a lifecycle.
    static let shared = ClaudeBridge()

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    @AppStorage(CortanaConstants.fridayChannelEnabledKey)
    private var fridayEnabled: Bool = true

    init() {
        canvasLog("[ClaudeBridge] initialized, active provider: \(ProviderManager.shared.activeProviderName)")
    }

    var isRunning: Bool { ProviderManager.shared.isRunning }

    var hasAPIAccess: Bool {
        ProviderManager.shared.activeProvider != nil
    }

    /// Human-readable name of the active provider for UI display
    var activeProviderName: String {
        if fridayEnabled && DaemonService.shared.isConnected {
            return "Friday (daemon)"
        }
        return ProviderManager.shared.activeProviderName
    }

    // MARK: - Send

    /// Primary entry point — accepts a fully-constructed ProviderSendContext so
    /// attachments, recentContext, and other fields are preserved on the direct path.
    /// Friday path forwards core fields; daemon handles its own context enrichment.
    func send(context: ProviderSendContext) -> AsyncStream<BridgeEvent> {
        if fridayEnabled && DaemonService.shared.isConnected {
            canvasLog("[ClaudeBridge] routing to Friday daemon, session=\(context.sessionId)")
            return wrapFridayWithFallback(
                message: context.message,
                sessionId: context.sessionId,
                branchId: context.branchId,
                model: context.model,
                workingDirectory: context.workingDirectory,
                project: context.project,
                checkpointContext: context.checkpointContext
            )
        }

        canvasLog("[ClaudeBridge] routing direct to \(ProviderManager.shared.activeProviderName), session=\(context.sessionId)")
        return ProviderManager.shared.send(context: context)
    }

    /// Legacy parameter-based entry point — used by CanvasServer and other callers
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
        // Route through Friday daemon if available and enabled
        if fridayEnabled && DaemonService.shared.isConnected {
            canvasLog("[ClaudeBridge] routing to Friday daemon, session=\(sessionId)")
            return wrapFridayWithFallback(
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

    // MARK: - Friday routing with fallback

    private func wrapFridayWithFallback(
        message: String,
        sessionId: String,
        branchId: String,
        model: String?,
        workingDirectory: String?,
        project: String?,
        checkpointContext: String?
    ) -> AsyncStream<BridgeEvent> {
        AsyncStream { continuation in
            Task { @MainActor in
                var receivedContent = false
                let fridayStream = await FridayChannel.shared.send(
                    text: message,
                    project: project,
                    branchId: branchId,
                    sessionId: sessionId
                )

                for await event in fridayStream {
                    // If first event is an error, fall through to direct provider
                    if case .error(let msg) = event, !receivedContent,
                       msg.contains("daemon not available") || msg.contains("Connection") {
                        canvasLog("[ClaudeBridge] Friday unavailable, falling back to direct provider")
                        let directStream = self.sendDirect(
                            message: message,
                            sessionId: sessionId,
                            branchId: branchId,
                            model: model,
                            workingDirectory: workingDirectory,
                            project: project,
                            checkpointContext: checkpointContext
                        )
                        for await directEvent in directStream {
                            continuation.yield(directEvent)
                        }
                        continuation.finish()
                        return
                    }
                    receivedContent = true
                    continuation.yield(event)
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

        var context = ProviderSendContext(
            message: message,
            sessionId: sessionId,
            branchId: branchId,
            model: model,
            workingDirectory: workingDirectory ?? resolveWorkingDirectory(nil, project: project),
            project: project,
            parentSessionId: parentSessionId,
            isNewSession: isNewSession
        )
        context.checkpointContext = checkpointContext

        canvasLog("[ClaudeBridge] routing to \(ProviderManager.shared.activeProviderName), session=\(sessionId), parent=\(parentSessionId ?? "none")")
        return ProviderManager.shared.send(context: context)
    }

    // MARK: - Cancel

    func cancel() {
        ProviderManager.shared.cancel()
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
        let messages = try? MessageStore.shared.getMessages(sessionId: sessionId)
        return (messages?.count ?? 0) > 0
    }

    /// Resolve working directory from project name
    private func resolveWorkingDirectory(_ explicit: String?, project: String?) -> String {
        if let dir = explicit, FileManager.default.fileExists(atPath: dir) {
            return dir
        }
        if let project {
            let devRoot = "\(home)/Development"
            let candidates = [
                "\(devRoot)/\(project)",
                "\(devRoot)/\(project.lowercased())",
                "\(devRoot)/\(project.replacingOccurrences(of: " ", with: "-"))",
            ]
            for path in candidates {
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return "\(home)/Development"
    }
}
