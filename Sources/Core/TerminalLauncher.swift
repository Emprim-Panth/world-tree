import Foundation
import GRDB

/// Opens a Ghostty + tmux terminal for a project, resuming the last Claude Code session.
///
/// Flow:
///   1. Look up the most recent `cli_session_id` from canvas_cli_sessions for this project path.
///   2. Create a named tmux session (`wt-{project}`) running `claude --resume {id}` if one doesn't exist.
///      If the session already exists, reuse it (user picks up exactly where they left off).
///   3. Open Ghostty attached to that tmux session.
@MainActor
final class TerminalLauncher {
    static let shared = TerminalLauncher()
    private init() {}

    private var db: DatabaseManager { .shared }

    private let ghosttyPath = "/opt/homebrew/bin/ghostty"
    private let tmuxPath    = "/opt/homebrew/bin/tmux"
    private let zshPath     = "/bin/zsh"

    // MARK: - Public

    func openTerminal(projectName: String, projectPath: String?, skipPermissions: Bool = false) {
        let rawPath  = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "~/Development"
        let expanded = (rawPath as NSString).expandingTildeInPath
        let resumeId = latestResumeId(forPath: rawPath)
        let tmuxName = tmuxSessionName(for: projectName)

        // Run synchronous process launches off the main thread
        Task.detached { [tmuxName, expanded, resumeId] in
            TerminalLauncher.launchTerminal(tmuxName: tmuxName, cwd: expanded, resumeId: resumeId, skipPermissions: skipPermissions)
        }
    }

    // MARK: - DB

    private func latestResumeId(forPath rawPath: String) -> String? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        do {
            guard let row = try db.read({ db in
                try Row.fetchOne(db, sql: """
                    SELECT c.cli_session_id
                    FROM canvas_cli_sessions c
                    JOIN sessions s ON s.id = c.canvas_session_id
                    WHERE s.working_directory = ? OR s.working_directory = ?
                    ORDER BY c.updated_at DESC
                    LIMIT 1
                    """, arguments: [expanded, rawPath])
            }) else { return nil }
            return row["cli_session_id"] as? String
        } catch {
            wtLog("[TerminalLauncher] Failed to look up resume ID for \(rawPath): \(error)")
            return nil
        }
    }

    // MARK: - Launch (nonisolated — only uses Process, no actor state)

    nonisolated private static func launchTerminal(tmuxName: String, cwd: String, resumeId: String?, skipPermissions: Bool) {
        let tmux    = "/opt/homebrew/bin/tmux"
        let ghostty = "/opt/homebrew/bin/ghostty"
        let zsh     = "/bin/zsh"

        // If session already exists, leave it alone — user reattaches to existing work
        let check = shell(zsh, ["-c", "\(tmux) has-session -t '\(tmuxName)' 2>/dev/null"])
        if check == 0 {
            // Session exists — just attach
            openGhostty(ghostty: ghostty, tmux: tmux, session: tmuxName)
            return
        }

        var claudeCmd = "claude"
        if skipPermissions { claudeCmd += " --dangerously-skip-permissions" }
        if let sid = resumeId { claudeCmd += " --resume \(sid)" }

        _ = shell(tmux, ["new-session", "-d", "-s", tmuxName, "-c", cwd, claudeCmd])
        openGhostty(ghostty: ghostty, tmux: tmux, session: tmuxName)
    }

    nonisolated private static func openGhostty(ghostty: String, tmux: String, session: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ghostty)
        p.arguments     = ["-e", tmux, "attach", "-t", session]
        try? p.run()
    }

    @discardableResult
    nonisolated private static func shell(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL  = URL(fileURLWithPath: path)
        p.arguments      = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func tmuxSessionName(for projectName: String) -> String {
        let safe = projectName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "wt-\(safe)"
    }
}
