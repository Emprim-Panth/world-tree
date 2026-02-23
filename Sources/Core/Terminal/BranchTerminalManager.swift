import AppKit
import Foundation
import SwiftTerm

// MARK: - tmux path resolution

/// Resolved tmux executable path — shared by BranchTerminalManager and ToolExecutor.
let tmuxExecutable: String = {
    let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/opt/homebrew/bin/tmux"
}()

// MARK: - CapturingTerminalView

/// LocalProcessTerminalView subclass that tees process output into a rolling byte buffer.
/// The buffer is read by ConversationStateManager to inject terminal context into Claude's prompt.
final class CapturingTerminalView: LocalProcessTerminalView {
    private let maxBytes = 8_000
    private(set) var capturedBytes = Data()

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        capturedBytes.append(contentsOf: slice)
        if capturedBytes.count > maxBytes {
            capturedBytes = capturedBytes.suffix(maxBytes)
        }
    }

    /// Recent terminal output: last ~60 lines, ANSI codes stripped.
    var recentOutput: String {
        guard let raw = String(data: capturedBytes, encoding: .utf8) else { return "" }
        // Strip ANSI escape sequences
        let ansi = try? NSRegularExpression(pattern: "\\x1B\\[[0-9;]*[mA-Za-z]|\\x1B[()][AB012]|\\x1B[=>]|\\r")
        let cleaned = ansi?.stringByReplacingMatches(
            in: raw,
            range: NSRange(raw.startIndex..., in: raw),
            withTemplate: ""
        ) ?? raw
        // Return last 60 lines
        let lines = cleaned.components(separatedBy: "\n")
        return lines.suffix(60).joined(separator: "\n")
    }
}

// MARK: - BranchTerminalManager

/// Singleton that owns one persistent PTY terminal per conversation branch.
///
/// Terminal processes survive view hide/show — switching branches doesn't kill the shell.
/// Chat execution is mirrored to the active branch's terminal so the user sees everything
/// Claude does in real time, and can take over or type alongside Claude at any moment.
@MainActor
final class BranchTerminalManager: ObservableObject {
    static let shared = BranchTerminalManager()

    /// branchId → live CapturingTerminalView (NSView held here, not in the view hierarchy)
    private var terminals: [String: CapturingTerminalView] = [:]

    /// Working directory per branch (for re-use if view recreates)
    private var workingDirs: [String: String] = [:]

    /// tmux session name per branch — persisted in DB, survives app restarts
    private var tmuxNames: [String: String] = [:]

    private init() {
        // Clean up all PTY processes when the app is about to quit.
        // This ensures zsh children receive SIGHUP gracefully rather than being
        // forcefully killed when the process exits. Registered once, never removed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.terminateAll()
            }
        }
    }

    // MARK: - Terminal Lifecycle

    /// Returns the existing terminal for this branch, or spawns a new one.
    /// Safe to call repeatedly — returns the same instance every time.
    ///
    /// Uses `tmux new-session -A -s canvas-{branchId}` so the tmux session
    /// survives app restarts. On next launch the SwiftTerm PTY reattaches to
    /// the running tmux daemon and shell state (history, processes) is intact.
    func getOrCreate(branchId: String, workingDirectory: String) -> CapturingTerminalView {
        if let existing = terminals[branchId] { return existing }

        let frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        let tv = CapturingTerminalView(frame: frame)

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")   // prevent nested-session guard
        env["TERM"] = "xterm-256color"

        // Use pre-loaded name from DB if available (app restart reattach path),
        // otherwise derive a new canonical name.
        let sessionName = tmuxNames[branchId] ?? tmuxSessionName(for: branchId)
        tmuxNames[branchId] = sessionName

        if FileManager.default.fileExists(atPath: tmuxExecutable) {
            // tmux available — attach-or-create for true persistence
            tv.startProcess(
                executable: tmuxExecutable,
                args: ["new-session", "-A", "-s", sessionName],
                environment: env.map { "\($0.key)=\($0.value)" },
                execName: "tmux",
                currentDirectory: workingDirectory
            )
            canvasLog("[BranchTerminalManager] tmux session '\(sessionName)' attached/created for \(branchId.prefix(8))")
        } else {
            // tmux not installed — fall back to plain zsh
            tv.startProcess(
                executable: "/bin/zsh",
                args: ["-i"],
                environment: env.map { "\($0.key)=\($0.value)" },
                execName: "zsh",
                currentDirectory: workingDirectory
            )
            canvasLog("[BranchTerminalManager] tmux not found; spawned plain zsh for \(branchId.prefix(8))")
        }

        terminals[branchId] = tv
        workingDirs[branchId] = workingDirectory

        // Persist the session name so the DB knows which tmux session owns this branch
        persistTmuxSessionName(sessionName, for: branchId)

        return tv
    }

    /// Canonical tmux session name for a branch.
    private func tmuxSessionName(for branchId: String) -> String {
        "canvas-\(branchId.prefix(8))"
    }

    /// Whether a branch has an active terminal process.
    func isActive(branchId: String) -> Bool {
        terminals[branchId] != nil
    }

    /// Persist the tmux session name to canvas_branches so it survives app restarts.
    private func persistTmuxSessionName(_ name: String, for branchId: String) {
        // Fire-and-forget; non-critical — worst case we just spawn a new-named session next launch
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            try? DatabaseManager.shared.write { db in
                try db.execute(
                    sql: "UPDATE canvas_branches SET tmux_session_name = ? WHERE id = ?",
                    arguments: [name, branchId]
                )
            }
        }
    }

    // MARK: - Session Name Access

    /// Returns the tmux session name for a branch, or nil if no terminal has been created.
    /// Used by ToolExecutor to route bash commands through the visible terminal.
    func sessionName(for branchId: String) -> String? {
        tmuxNames[branchId]
    }

    // MARK: - Agent Windows

    /// Open a new named tmux window in the branch's session for an agent task.
    /// Each agent gets its own tab — Evan can switch between them in the terminal.
    func openAgentWindow(branchId: String, name: String) {
        guard let sessionName = tmuxNames[branchId],
              FileManager.default.fileExists(atPath: tmuxExecutable) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxExecutable)
        proc.arguments = ["new-window", "-t", sessionName, "-n", name]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        canvasLog("[BranchTerminalManager] opened agent window '\(name)' in \(sessionName)")
    }

    // MARK: - PTY Input

    /// Write text to the branch's PTY stdin — appears exactly as if the user typed it.
    func send(to branchId: String, text: String) {
        guard let tv = terminals[branchId] else { return }
        let bytes = ArraySlice(Array(text.utf8))
        tv.send(source: tv, data: bytes)
    }

    // MARK: - Terminal Output Capture

    /// Returns the last ~60 lines of process output for a branch, ANSI codes stripped.
    /// Used by ConversationStateManager to inject terminal context into Claude's system prompt.
    func getRecentOutput(branchId: String) -> String {
        terminals[branchId]?.recentOutput ?? ""
    }

    // MARK: - Lifecycle Management

    /// Pre-warm a terminal for a branch (called from UI layer on branch selection).
    /// Accepts an optional pre-known tmux session name from the DB so that on app
    /// restart we reattach to the exact same tmux session that was running before.
    func warmUp(branchId: String, workingDirectory: String, knownTmuxSession: String? = nil) {
        // If we know the tmux session name from the DB, register it so getOrCreate uses it
        if let name = knownTmuxSession {
            tmuxNames[branchId] = name
        }
        _ = getOrCreate(branchId: branchId, workingDirectory: workingDirectory)
    }

    /// Terminate a branch's terminal process (branch archived or deleted).
    /// Also kills the tmux session so it doesn't linger as an orphan.
    func terminate(branchId: String) {
        terminals[branchId]?.terminate()
        terminals.removeValue(forKey: branchId)
        workingDirs.removeValue(forKey: branchId)

        // Kill the tmux session too (fire-and-forget)
        if let sessionName = tmuxNames.removeValue(forKey: branchId),
           FileManager.default.fileExists(atPath: tmuxExecutable) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: tmuxExecutable)
            task.arguments = ["kill-session", "-t", sessionName]
            try? task.run()
        }

        canvasLog("[BranchTerminalManager] Terminated terminal for \(branchId.prefix(8))")
    }

    /// Terminate all terminals (app quit).
    /// Does NOT kill tmux sessions on quit — that's the whole point of persistence.
    func terminateAll() {
        for (_, tv) in terminals { tv.terminate() }
        terminals.removeAll()
        workingDirs.removeAll()
        tmuxNames.removeAll()
    }
}
