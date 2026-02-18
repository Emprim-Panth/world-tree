import SwiftUI
import SwiftTerm

// MARK: - CanvasLocalTerminal

/// A real PTY terminal embedded in Canvas.
/// Wraps SwiftTerm's LocalProcessTerminalView — full VT100, ANSI colors, ncurses,
/// cursor movement, interactive programs (vim, htop, claude) all work correctly.
///
/// Starts `/bin/zsh` in the tree's working directory.
/// Toggle with ⌘` in the document view.
struct CanvasLocalTerminal: NSViewRepresentable {
    let workingDirectory: String

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: .zero)

        // Build environment:
        // - Strip CLAUDECODE so running claude from this terminal doesn't trip
        //   the nested-session guard (Canvas may be launched from a CLI session)
        // - Set TERM so colors, ncurses, and cursor apps work correctly
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env["TERM"] = "xterm-256color"
        let envArray = env.map { "\($0.key)=\($0.value)" }

        // "cd to project dir, then exec a full interactive zsh" gives us:
        // correct $PWD, shell history, completions, rc files, everything.
        tv.startProcess(
            executable: "/bin/zsh",
            args: ["-c", "cd \(workingDirectory.shellQuoted) && exec zsh -i"],
            environment: envArray,
            execName: "zsh"
        )

        return tv
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Working directory is baked in at process start — no live updates needed.
    }
}

// MARK: - String helpers

private extension String {
    /// Single-quote the path so spaces and special characters are safe in shell args.
    var shellQuoted: String {
        "'\(self.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
