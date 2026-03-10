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

    /// Release captured output buffer and terminate the underlying PTY process.
    /// Call this instead of bare `terminate()` to ensure resources are fully freed.
    func cleanup() {
        capturedBytes = Data()
        terminate()
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

    /// Retained token for the willTerminate observer. Must be stored or the observer
    /// is immediately deregistered (block-based addObserver returns a token that
    /// must be kept alive). Singleton lives for app lifetime so no removeObserver needed.
    private var terminationObserver: NSObjectProtocol?

    private init() {
        // Clean up all PTY processes when the app is about to quit.
        // This ensures zsh children receive SIGHUP gracefully rather than being
        // forcefully killed when the process exits. Registered once, never removed.
        terminationObserver = NotificationCenter.default.addObserver(
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
            wtLog("[BranchTerminalManager] tmux session '\(sessionName)' attached/created for \(branchId.prefix(8))")
        } else {
            // tmux not installed — fall back to plain zsh
            tv.startProcess(
                executable: "/bin/zsh",
                args: ["-i"],
                environment: env.map { "\($0.key)=\($0.value)" },
                execName: "zsh",
                currentDirectory: workingDirectory
            )
            wtLog("[BranchTerminalManager] tmux not found; spawned plain zsh for \(branchId.prefix(8))")
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

    // MARK: - Project-Level Terminals

    /// Project terminals keyed by project name — persistent across branches.
    private var projectTerminals: [String: CapturingTerminalView] = [:]
    private var projectTmuxNames: [String: String] = [:]

    /// Returns the existing project terminal, or spawns a new one.
    /// Project terminals use `wt-{projectName}` tmux sessions and persist across branch switches.
    func getOrCreateProjectTerminal(project: String, workingDirectory: String) -> CapturingTerminalView {
        if let existing = projectTerminals[project] { return existing }

        let frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        let tv = CapturingTerminalView(frame: frame)

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env["TERM"] = "xterm-256color"

        let sessionName = projectTmuxNames[project] ?? "wt-\(project.lowercased().replacingOccurrences(of: " ", with: "-"))"
        projectTmuxNames[project] = sessionName

        if FileManager.default.fileExists(atPath: tmuxExecutable) {
            tv.startProcess(
                executable: tmuxExecutable,
                args: ["new-session", "-A", "-s", sessionName],
                environment: env.map { "\($0.key)=\($0.value)" },
                execName: "tmux",
                currentDirectory: workingDirectory
            )
            wtLog("[BranchTerminalManager] project tmux '\(sessionName)' attached/created for \(project)")
        } else {
            tv.startProcess(
                executable: "/bin/zsh",
                args: ["-i"],
                environment: env.map { "\($0.key)=\($0.value)" },
                execName: "zsh",
                currentDirectory: workingDirectory
            )
        }

        projectTerminals[project] = tv
        return tv
    }

    /// Whether a project has an active terminal.
    func isProjectTerminalActive(project: String) -> Bool {
        projectTerminals[project] != nil
    }

    /// tmux session name for a project terminal.
    func projectSessionName(for project: String) -> String? {
        projectTmuxNames[project]
    }

    /// Recent output from a project terminal.
    func getProjectRecentOutput(project: String) -> String {
        projectTerminals[project]?.recentOutput ?? ""
    }

    /// Send text to a project terminal (as keyboard input to the process).
    func sendToProject(_ project: String, text: String) {
        guard let tv = projectTerminals[project] else { return }
        let bytes = ArraySlice(Array(text.utf8))
        tv.send(source: tv, data: bytes)
    }

    /// Mirror text to a project terminal's display — bypasses the shell process entirely.
    /// Used to show Claude's live output (tool calls, results, text) without typing into zsh.
    func mirrorToProject(_ project: String, text: String) {
        guard let tv = projectTerminals[project] else { return }
        tv.feed(text: text)
    }

    // MARK: - Agent Terminals (Hidden)

    /// Agent terminals for background work — hidden from main view.
    private var agentTerminals: [String: CapturingTerminalView] = [:]

    /// Spawn a hidden tmux session for agent work. Returns the terminal for output capture.
    /// Session is named `wt-agent-{jobId}` and doesn't appear in the main terminal panel.
    @discardableResult
    func spawnAgentTerminal(jobId: String, workingDirectory: String) -> CapturingTerminalView {
        if let existing = agentTerminals[jobId] { return existing }

        let frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        let tv = CapturingTerminalView(frame: frame)

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env["TERM"] = "xterm-256color"

        let sessionName = "wt-agent-\(jobId.prefix(8))"

        if FileManager.default.fileExists(atPath: tmuxExecutable) {
            tv.startProcess(
                executable: tmuxExecutable,
                args: ["new-session", "-A", "-s", sessionName],
                environment: env.map { "\($0.key)=\($0.value)" },
                execName: "tmux",
                currentDirectory: workingDirectory
            )
            wtLog("[BranchTerminalManager] agent tmux '\(sessionName)' spawned for job \(jobId.prefix(8))")
        } else {
            tv.startProcess(
                executable: "/bin/zsh",
                args: ["-i"],
                environment: env.map { "\($0.key)=\($0.value)" },
                execName: "zsh",
                currentDirectory: workingDirectory
            )
        }

        agentTerminals[jobId] = tv
        return tv
    }

    /// Terminate an agent terminal and kill its tmux session.
    func terminateAgentTerminal(jobId: String) {
        agentTerminals[jobId]?.cleanup()
        agentTerminals.removeValue(forKey: jobId)

        let sessionName = "wt-agent-\(jobId.prefix(8))"
        if FileManager.default.fileExists(atPath: tmuxExecutable) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: tmuxExecutable)
            task.arguments = ["kill-session", "-t", sessionName]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
        }
        wtLog("[BranchTerminalManager] agent terminal terminated for job \(jobId.prefix(8))")
    }

    /// Get captured output from an agent terminal.
    func getAgentOutput(jobId: String) -> String {
        agentTerminals[jobId]?.recentOutput ?? ""
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
        wtLog("[BranchTerminalManager] opened agent window '\(name)' in \(sessionName)")
    }

    // MARK: - PTY Input

    /// Write text to the branch's PTY stdin — appears exactly as if the user typed it.
    func send(to branchId: String, text: String) {
        guard let tv = terminals[branchId] else { return }
        let bytes = ArraySlice(Array(text.utf8))
        tv.send(source: tv, data: bytes)
    }

    /// Mirror text to a branch terminal's display — bypasses the shell process entirely.
    /// Used to show Claude's live output without typing into the shell.
    func mirror(to branchId: String, text: String) {
        guard let tv = terminals[branchId] else { return }
        tv.feed(text: text)
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
    /// Releases captured output buffers and cleans up the PTY file descriptors.
    func terminate(branchId: String) {
        terminals[branchId]?.cleanup()
        terminals.removeValue(forKey: branchId)
        workingDirs.removeValue(forKey: branchId)

        // Kill the tmux session too (fire-and-forget)
        if let sessionName = tmuxNames.removeValue(forKey: branchId),
           FileManager.default.fileExists(atPath: tmuxExecutable) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: tmuxExecutable)
            task.arguments = ["kill-session", "-t", sessionName]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
        }

        wtLog("[BranchTerminalManager] Terminated terminal for \(branchId.prefix(8))")
    }

    /// Terminate all terminals (app quit).
    /// Does NOT kill tmux sessions on quit — that's the whole point of persistence.
    /// Releases all captured output buffers and cleans up PTY file descriptors.
    func terminateAll() {
        for (_, tv) in terminals { tv.cleanup() }
        terminals.removeAll()
        workingDirs.removeAll()
        tmuxNames.removeAll()

        for (_, tv) in projectTerminals { tv.cleanup() }
        projectTerminals.removeAll()
        projectTmuxNames.removeAll()

        // Agent terminals ARE killed on quit — they're ephemeral
        for (jobId, tv) in agentTerminals {
            tv.cleanup()
            let sessionName = "wt-agent-\(jobId.prefix(8))"
            if FileManager.default.fileExists(atPath: tmuxExecutable) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: tmuxExecutable)
                task.arguments = ["kill-session", "-t", sessionName]
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                try? task.run()
            }
        }
        agentTerminals.removeAll()
    }

    // MARK: - Session Verification

    /// Verify a tmux session is still alive. If dead, clean up the stale mapping.
    /// Returns true if the session is valid, false if it was cleaned up.
    /// Non-blocking — uses async continuation with terminationHandler.
    @discardableResult
    func verifySession(branchId: String) async -> Bool {
        guard let sessionName = tmuxNames[branchId],
              FileManager.default.fileExists(atPath: tmuxExecutable) else {
            return false
        }

        let tmuxPath = tmuxExecutable
        let alive = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tmuxPath)
            proc.arguments = ["has-session", "-t", sessionName]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice

            proc.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(returning: false)
            }
        }

        if !alive {
            terminals.removeValue(forKey: branchId)
            workingDirs.removeValue(forKey: branchId)
            tmuxNames.removeValue(forKey: branchId)
            wtLog("[BranchTerminalManager] Cleaned up stale tmux session '\(sessionName)' for \(branchId.prefix(8))")
        }
        return alive
    }

    /// Recover orphaned tmux sessions on app launch.
    /// Scans tmux for canvas-* sessions and checks if we have branch mappings for them.
    /// Scan for orphaned canvas-* tmux sessions on app launch.
    /// Non-blocking — uses terminationHandler instead of waitUntilExit.
    func recoverOrphanedSessions() {
        guard FileManager.default.fileExists(atPath: tmuxExecutable) else { return }

        let tmuxPath = tmuxExecutable
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxPath)
        proc.arguments = ["list-sessions", "-F", "#{session_name}"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // Close the pipe's read handle — process is done, no more data coming.
            try? pipe.fileHandleForReading.close()
            guard let output = String(data: data, encoding: .utf8) else { return }

            let allSessions = output.split(separator: "\n").map(String.init)
            let canvasSessions = allSessions.filter { $0.hasPrefix("canvas-") }
            let projectSessions = allSessions.filter { $0.hasPrefix("wt-") && !$0.hasPrefix("wt-agent-") }

            Task { @MainActor [weak self] in
                guard let self else { return }
                let knownBranch = Set(self.tmuxNames.values)
                let knownProject = Set(self.projectTmuxNames.values)
                let branchOrphans = canvasSessions.filter { !knownBranch.contains($0) }
                let projectOrphans = projectSessions.filter { !knownProject.contains($0) }
                let allOrphans = branchOrphans + projectOrphans
                if !allOrphans.isEmpty {
                    wtLog("[BranchTerminalManager] Found \(allOrphans.count) orphaned tmux session(s): \(allOrphans.joined(separator: ", "))")
                }
            }
        }

        do {
            try proc.run()
        } catch {
            // Process failed to launch — close the pipe to avoid leaking the fd.
            try? pipe.fileHandleForReading.close()
            wtLog("[BranchTerminalManager] Failed to list tmux sessions: \(error)")
        }
    }
}
