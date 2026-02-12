import Foundation

/// Events yielded during a conversation turn — text streaming, tool activity, completion.
enum BridgeEvent {
    case text(String)
    case toolStart(name: String, input: String)
    case toolEnd(name: String, result: String, isError: Bool)
    case done(usage: SessionTokenUsage)
    case error(String)
}

/// Thin delegate that routes messages through ProviderManager.
/// Maintains the same `send()` interface that BranchViewModel expects.
@MainActor
final class ClaudeBridge {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    init() {
        canvasLog("[ClaudeBridge] initialized, active provider: \(ProviderManager.shared.activeProviderName)")
    }

    var isRunning: Bool { ProviderManager.shared.isRunning }

    var hasAPIAccess: Bool {
        ProviderManager.shared.activeProvider != nil
    }

    /// Human-readable name of the active provider for UI display
    var activeProviderName: String {
        ProviderManager.shared.activeProviderName
    }

    // MARK: - Send

    func send(
        message: String,
        sessionId: String,
        branchId: String,
        model: String?,
        workingDirectory: String?,
        project: String?
    ) -> AsyncStream<BridgeEvent> {
        // Resolve parent session for fork/resume inheritance
        let parentSessionId = resolveParentSessionId(branchId: branchId)
        let isNewSession = !hasExistingSession(sessionId: sessionId)

        let context = ProviderSendContext(
            message: message,
            sessionId: sessionId,
            branchId: branchId,
            model: model,
            workingDirectory: workingDirectory ?? resolveWorkingDirectory(nil, project: project),
            project: project,
            parentSessionId: parentSessionId,
            isNewSession: isNewSession
        )

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
