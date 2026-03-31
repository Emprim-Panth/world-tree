import Foundation
import Observation

/// Manages Claude Code PTY sessions embedded in World Tree.
@MainActor
@Observable
final class SessionManager {
    static let shared = SessionManager()

    private(set) var sessions: [ManagedSession] = []
    var activeSessionID: UUID?

    struct ManagedSession: Identifiable {
        let id: UUID
        let claudeSessionID: String  // for --session-id / --resume
        let project: String
        let projectPath: String
        var state: SessionState = .running
        let createdAt: Date = Date()
        var skipPermissions: Bool = false

        enum SessionState: String {
            case running, paused, ended, crashed
        }

        var isActive: Bool { state == .running }

        var claudeArguments: [String] {
            var args = ["--session-id", claudeSessionID]
            if skipPermissions {
                args.append("--dangerously-skip-permissions")
            }
            return args
        }

        var resumeArguments: [String] {
            var args = ["--resume", claudeSessionID]
            if skipPermissions {
                args.append("--dangerously-skip-permissions")
            }
            return args
        }
    }

    private init() {}

    // MARK: - Session Lifecycle

    func createSession(project: String, projectPath: String, skipPermissions: Bool = false, resumeID: String? = nil) -> ManagedSession {
        let sessionID = UUID()
        let claudeID = resumeID ?? sessionID.uuidString

        let session = ManagedSession(
            id: sessionID,
            claudeSessionID: claudeID,
            project: project,
            projectPath: projectPath,
            skipPermissions: skipPermissions
        )

        sessions.append(session)
        activeSessionID = sessionID

        wtLog("[SessionManager] Created session \(sessionID) for \(project)")
        return session
    }

    func sessionExited(id: UUID, exitCode: Int32) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].state = exitCode == 0 ? .ended : .crashed
        wtLog("[SessionManager] Session \(id) exited with code \(exitCode)")
    }

    func removeSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        if activeSessionID == id {
            activeSessionID = sessions.first?.id
        }
    }

    func switchTo(id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        activeSessionID = id
    }

    var activeSession: ManagedSession? {
        sessions.first { $0.id == activeSessionID }
    }

    var claudeExecutable: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin/claude"
    }

    // MARK: - Cleanup

    func terminateAll() {
        sessions.removeAll()
        activeSessionID = nil
    }
}
