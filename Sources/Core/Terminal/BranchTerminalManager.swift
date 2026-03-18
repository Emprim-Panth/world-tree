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

    /// Published version counter per terminal key (branchId or "project-{name}").
    /// Incremented by the watchdog when a dead terminal is detected — SwiftUI views
    /// use this as part of their `.id()` so they recreate the PTY when it changes.
    @Published private(set) var terminalVersions: [String: Int] = [:]

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
        startWatchdog()
    }

    // MARK: - Watchdog

    /// Starts a background loop that checks every 45s whether all tracked tmux sessions
    /// are still alive. Detects tmux server crashes (all sessions die simultaneously)
    /// and individual pane deaths. Increments `terminalVersions` when a dead session is
    /// detected — SwiftUI terminal views observe this and force a PTY reconnect.
    private func startWatchdog() {
        Task.detached(priority: .utility) { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(45))
                await self?.runWatchdogCycle()
            }
        }
    }

    @MainActor
    private func runWatchdogCycle() async {
        // Branch terminals
        let branchIds = Array(tmuxNames.keys)
        for branchId in branchIds {
            let alive = await verifySession(branchId: branchId)
            if !alive {
                // Session was dead — bump version so the UI recreates the terminal view
                terminalVersions[branchId, default: 0] += 1
                wtLog("[BranchTerminalManager] Watchdog: branch terminal \(branchId.prefix(8)) was dead — signaling UI reconnect")
            }
        }

        // Project terminals
        let projectNames = Array(projectTmuxNames.keys)
        for project in projectNames {
            let alive = await verifyProjectTerminal(project: project)
            if !alive {
                terminalVersions["project-\(project)", default: 0] += 1
                wtLog("[BranchTerminalManager] Watchdog: project terminal '\(project)' was dead — signaling UI reconnect")
            }
        }
    }

    /// Verify a project-level tmux session is still alive.
    /// Mirrors verifySession(branchId:) for project terminals.
    @discardableResult
    func verifyProjectTerminal(project: String) async -> Bool {
        guard let sessionName = projectTmuxNames[project],
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
            do { try proc.run() } catch { continuation.resume(returning: false) }
        }

        if !alive {
            projectTerminals[project]?.cleanup()
            projectTerminals.removeValue(forKey: project)
            projectTmuxNames.removeValue(forKey: project)
            wtLog("[BranchTerminalManager] Cleaned up stale project tmux session '\(sessionName)' for '\(project)'")
            return false
        }

        // Check pane liveness and respawn if dead
        let paneAlive = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tmuxPath)
            proc.arguments = ["list-panes", "-t", sessionName, "-F", "#{pane_dead}"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            proc.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "1"
                continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
            }
            do { try proc.run() } catch { continuation.resume(returning: true) }
        }

        if !paneAlive {
            let workDir = FileManager.default.homeDirectoryForCurrentUser.path
            let respawnProc = Process()
            respawnProc.executableURL = URL(fileURLWithPath: tmuxPath)
            respawnProc.arguments = ["respawn-pane", "-t", sessionName, "-k", "-c", workDir]
            respawnProc.standardOutput = FileHandle.nullDevice
            respawnProc.standardError = FileHandle.nullDevice
            try? respawnProc.run()
            respawnProc.waitUntilExit()
            wtLog("[BranchTerminalManager] Respawned dead pane in project session '\(sessionName)'")
        }

        return true
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

        // Register in cache BEFORE starting the process — prevents a double-fork if
        // getOrCreate is called again before the deferred startProcess fires.
        terminals[branchId] = tv
        workingDirs[branchId] = workingDirectory

        // Persist the session name so the DB knows which tmux session owns this branch
        persistTmuxSessionName(sessionName, for: branchId)

        // Defer forkpty() out of the synchronous makeNSView / view-init path.
        //
        // forkpty() in a multi-threaded process is unsafe when the Swift runtime holds
        // an os_unfair_lock on any cooperative pool thread — guaranteed during app startup.
        // The child inherits the locked lock but not the owning thread, which causes
        // _os_unfair_lock_corruption_abort → SIGKILL (crash within ~22ms of launch).
        //
        // 100ms lets the generic-metadata instantiation burst settle before the fork,
        // while remaining imperceptibly fast to the user (terminal is blank for < 0.1s).
        Task { @MainActor [weak self, weak tv] in
            guard let self, let tv else { return }
            try? await Task.sleep(for: .milliseconds(100))
            if FileManager.default.fileExists(atPath: tmuxExecutable) {
                tv.startProcess(
                    executable: tmuxExecutable,
                    args: ["new-session", "-A", "-s", sessionName],
                    environment: env.map { "\($0.key)=\($0.value)" },
                    execName: "tmux",
                    currentDirectory: workingDirectory
                )
                wtLog("[BranchTerminalManager] tmux session '\(sessionName)' attached/created for \(branchId.prefix(8))")
                self.enhanceTmuxSession(name: sessionName, branchId: branchId, workingDirectory: workingDirectory)
                self.initializeProjectSession(name: sessionName, workingDirectory: workingDirectory)
            } else {
                tv.startProcess(
                    executable: "/bin/zsh",
                    args: ["-i"],
                    environment: env.map { "\($0.key)=\($0.value)" },
                    execName: "zsh",
                    currentDirectory: workingDirectory
                )
                wtLog("[BranchTerminalManager] tmux not found; spawned plain zsh for \(branchId.prefix(8))")
            }
        }

        return tv
    }

    /// Canonical tmux session name for a branch.
    private func tmuxSessionName(for branchId: String) -> String {
        "canvas-\(branchId.prefix(8))"
    }

    // MARK: - tmux Session Enhancements

    /// Configure a tmux session with enhanced features after creation.
    /// Called once per session — sets environment, pipe-pane, hooks, monitoring, status line,
    /// command audit trail, and lifecycle tracking.
    private func enhanceTmuxSession(name: String, branchId: String, workingDirectory: String) {
        guard FileManager.default.fileExists(atPath: tmuxExecutable) else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let streamDir = "\(home)/.cortana/streams"
        let eventDir = "\(home)/.cortana/worldtree/events"
        let auditDir = "\(home)/.cortana/worldtree/audit"

        // Ensure directories exist
        for dir in [streamDir, eventDir, auditDir] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // Derive a display label for the status bar
        let projectName = URL(fileURLWithPath: workingDirectory).lastPathComponent
        let shortBranch = String(branchId.prefix(8))

        let commands: [(description: String, args: [String])] = [
            // ── 1. Environment — per-session context for all child processes ──
            ("set BRANCH_ID", ["set-environment", "-t", name, "BRANCH_ID", shortBranch]),
            ("set CORTANA_SESSION", ["set-environment", "-t", name, "CORTANA_SESSION", "1"]),
            ("set PROJECT_DIR", ["set-environment", "-t", name, "PROJECT_DIR", workingDirectory]),
            ("set SESSION_NAME", ["set-environment", "-t", name, "TMUX_SESSION_NAME", name]),

            // ── 2. Pipe-pane — stream output to log for live monitoring ──
            ("pipe-pane", ["pipe-pane", "-t", name, "-o",
                           "cat >> '\(streamDir)/\(name).log'"]),

            // ── 3. Monitor-silence — detect command completion (5s quiet) ──
            ("monitor-silence", ["set-option", "-t", name, "monitor-silence", "5"]),

            // ── 4. Status line — show project, branch, current command, cwd at a glance ──
            //    Left: project/branch identity. Right: live command + working directory.
            ("status on", ["set-option", "-t", name, "status", "on"]),
            ("status-style", ["set-option", "-t", name, "status-style", "bg=#1a1a2e,fg=#8888aa"]),
            ("status-left", ["set-option", "-t", name, "status-left",
                             "#[fg=#64ffda,bold] \(projectName) #[fg=#555]│#[fg=#bb86fc] \(shortBranch) #[fg=#555]│ "]),
            ("status-right", ["set-option", "-t", name, "status-right",
                              "#[fg=#888]#{pane_current_command} #[fg=#555]│#[fg=#666] #{pane_current_path} "]),
            ("status-left-length", ["set-option", "-t", name, "status-left-length", "50"]),
            ("status-right-length", ["set-option", "-t", name, "status-right-length", "80"]),
            ("status-interval", ["set-option", "-t", name, "status-interval", "2"]),

            // ── 5. Hooks — event-driven lifecycle + audit ──

            // pane-died: shell process exited (crash, exit, killed)
            ("hook pane-died", ["set-hook", "-t", name, "pane-died",
                                "run-shell 'echo pane-died > \(eventDir)/\(name).event'"]),

            // alert-silence: no output for monitor-silence seconds (command finished)
            ("hook alert-silence", ["set-hook", "-t", name, "alert-silence",
                                    "run-shell 'echo silence > \(eventDir)/\(name).event'"]),

            // session-closed: session was destroyed (killed externally, user exit, etc.)
            ("hook session-closed", ["set-hook", "-t", name, "session-closed",
                                     "run-shell 'echo session-closed > \(eventDir)/\(name).event'"]),

            // after-send-keys: command audit trail — log every keystroke sent to the session.
            // Writes timestamp + pane command to the audit log for full history.
            // NOTE: tmux run-shell uses sh, so date format works directly. The %% escaping
            // is needed because tmux format strings treat % specially.
            ("hook after-send-keys", ["set-hook", "-t", name, "after-send-keys",
                                      "run-shell \"date '+%Y-%m-%dT%H:%M:%S #{pane_current_command} #{pane_current_path}' >> \(auditDir)/\(name).audit\""]),

            // ── 6. Mouse support — enable scroll, click, and resize via trackpad/mouse ──
            ("mouse on", ["set-option", "-t", name, "mouse", "on"]),

            // ── 7. Pane border labels — identify panes at a glance ──
            ("pane-border-status", ["set-option", "-t", name, "pane-border-status", "top"]),
            ("pane-border-format", ["set-option", "-t", name, "pane-border-format",
                                    "#[fg=#64ffda] #{pane_current_command} #[fg=#555]│ #{pane_current_path}"]),
        ]

        // Run enhancements off the main thread to avoid blocking UI.
        // Each command waits for the previous one — tmux can't handle concurrent set-option calls
        // reliably when they all target the same session.
        let tmuxPath = tmuxExecutable
        let sessionName = name
        Task.detached(priority: .utility) {
            for (desc, args) in commands {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: tmuxPath)
                proc.arguments = args
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                    proc.waitUntilExit()
                } catch {
                    wtLog("[BranchTerminalManager] Failed to \(desc) for \(sessionName): \(error)")
                }
            }
            wtLog("[BranchTerminalManager] Enhanced tmux session '\(sessionName)' — env, pipe, hooks, status, audit, borders")
        }
    }

    // MARK: - tmux Session Queries

    /// Snapshot of a tmux session's real-time state — what's running, where, how long idle.
    struct SessionState {
        let sessionName: String
        let currentCommand: String    // e.g. "zsh", "cargo", "claude", "python"
        let currentPath: String       // live working directory (tracks cd)
        let panePid: Int
        let idleSeconds: Int          // seconds since last output
        let paneWidth: Int
        let paneHeight: Int

        /// Whether the session appears idle (shell prompt, not running a command).
        var isIdle: Bool {
            ["zsh", "bash", "fish", "sh"].contains(currentCommand.lowercased())
        }

        /// Whether Claude is actively running in this session.
        var isClaudeActive: Bool {
            currentCommand.lowercased().contains("claude")
        }
    }

    /// Query the real-time state of a tmux session — what's running, cwd, idle time.
    /// Uses tmux format variables for instant, accurate answers without parsing output.
    func querySessionState(sessionName: String) async -> SessionState? {
        guard FileManager.default.fileExists(atPath: tmuxExecutable) else { return nil }

        let tmuxPath = tmuxExecutable
        return await withCheckedContinuation { (continuation: CheckedContinuation<SessionState?, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tmuxPath)
            // Query multiple format variables in one call — pipe-separated for easy parsing
            proc.arguments = ["display-message", "-t", sessionName, "-p",
                              "#{pane_current_command}||#{pane_current_path}||#{pane_pid}||#{pane_idle}||#{pane_width}||#{pane_height}"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice

            proc.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                      !output.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                let fields = output.components(separatedBy: "||")
                guard fields.count >= 6 else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: SessionState(
                    sessionName: sessionName,
                    currentCommand: fields[0],
                    currentPath: fields[1],
                    panePid: Int(fields[2]) ?? 0,
                    idleSeconds: Int(fields[3]) ?? 0,
                    paneWidth: Int(fields[4]) ?? 80,
                    paneHeight: Int(fields[5]) ?? 24
                ))
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Query all active sessions' states in a single batch.
    /// Returns a dictionary of sessionName → SessionState.
    func queryAllSessionStates() async -> [String: SessionState] {
        let allNames = Array(tmuxNames.values) + Array(projectTmuxNames.values)
        guard !allNames.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, SessionState?).self) { group in
            for name in allNames {
                group.addTask { [weak self] in
                    let state = await self?.querySessionState(sessionName: name)
                    return (name, state)
                }
            }

            var results: [String: SessionState] = [:]
            for await (name, state) in group {
                if let state { results[name] = state }
            }
            return results
        }
    }

    /// Get the live working directory for a branch's terminal.
    /// Unlike `workingDirs` (set at creation), this tracks `cd` commands in real time.
    func liveWorkingDirectory(branchId: String) async -> String? {
        guard let sessionName = tmuxNames[branchId] else { return nil }
        return await querySessionState(sessionName: sessionName)?.currentPath
    }

    /// Get what's currently running in a branch's terminal.
    func currentCommand(branchId: String) async -> String? {
        guard let sessionName = tmuxNames[branchId] else { return nil }
        return await querySessionState(sessionName: sessionName)?.currentCommand
    }

    /// Read the command audit trail for a session.
    /// Returns the last N entries from the audit log.
    func auditTrail(sessionName: String, entries: Int = 50) -> [String] {
        let auditPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cortana/worldtree/audit/\(sessionName).audit"
        guard let data = FileManager.default.contents(atPath: auditPath),
              let content = String(data: data, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        return Array(lines.suffix(entries))
    }

    /// Read live output from a session's pipe-pane log.
    /// Returns the last N lines from the streaming log file.
    func liveOutput(sessionName: String, lines: Int = 50) -> String {
        let logPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cortana/streams/\(sessionName).log"
        guard let data = FileManager.default.contents(atPath: logPath),
              let content = String(data: data, encoding: .utf8) else { return "" }
        let allLines = content.components(separatedBy: "\n")
        return allLines.suffix(lines).joined(separator: "\n")
    }

    /// Check and consume the latest event for a session (pane-died, silence, session-closed, etc.)
    func consumeEvent(sessionName: String) -> String? {
        let eventPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cortana/worldtree/events/\(sessionName).event"
        guard let data = FileManager.default.contents(atPath: eventPath),
              let event = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !event.isEmpty else { return nil }
        // Consume by removing the file
        try? FileManager.default.removeItem(atPath: eventPath)
        return event
    }

    /// Truncate a session's pipe-pane log to prevent unbounded growth.
    /// Called periodically (e.g., from heartbeat or on session switch).
    func rotatePipeLog(sessionName: String, keepLines: Int = 500) {
        let logPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cortana/streams/\(sessionName).log"
        guard let data = FileManager.default.contents(atPath: logPath),
              let content = String(data: data, encoding: .utf8) else { return }
        let allLines = content.components(separatedBy: "\n")
        if allLines.count > keepLines {
            let trimmed = allLines.suffix(keepLines).joined(separator: "\n")
            try? trimmed.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
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

    /// Resolve the terminal session that should represent this chat.
    /// Project-backed conversations prefer the shared project terminal because that is
    /// the pane World Tree actually presents to the user.
    func preferredSessionName(branchId: String, project: String?) -> String? {
        if let project {
            return canonicalProjectSessionName(for: project)
        }
        return tmuxNames[branchId]
    }

    /// Materialize the preferred terminal for this chat and return the tmux session name.
    /// Tool execution should call this before routing through tmux so project-backed chats
    /// bind to the real `wt-*` session instead of racing the UI and falling back to `canvas-*`.
    @discardableResult
    func preparePreferredSession(
        branchId: String,
        project: String?,
        workingDirectory: String,
        knownTmuxSession: String? = nil
    ) -> String? {
        warmUpPreferred(
            branchId: branchId,
            project: project,
            workingDirectory: workingDirectory,
            knownTmuxSession: knownTmuxSession
        )
        return preferredSessionName(branchId: branchId, project: project)
    }

    /// Recent output from the terminal this chat actually owns.
    /// Falls back to pipe-pane logs when the NSView-backed terminal is not materialized yet.
    func preferredRecentOutput(branchId: String, project: String?) -> String {
        if let project {
            if let output = projectTerminals[project]?.recentOutput, !output.isEmpty {
                return output
            }
            let sessionName = canonicalProjectSessionName(for: project)
            let output = liveOutput(sessionName: sessionName)
            if !output.isEmpty {
                return output
            }
        }

        if let output = terminals[branchId]?.recentOutput, !output.isEmpty {
            return output
        }
        if let sessionName = tmuxNames[branchId] {
            let output = liveOutput(sessionName: sessionName)
            if !output.isEmpty {
                return output
            }
        }
        return ""
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

        // Cache immediately — before startProcess — so any re-entrant call (e.g. makeNSView
        // during NSHostingView layout sizing) returns this instance without double-spawning.
        projectTerminals[project] = tv

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env["TERM"] = "xterm-256color"
        let envList = env.map { "\($0.key)=\($0.value)" }

        // Defer forkpty() out of the synchronous makeNSView / view-init path.
        // See getOrCreate(branchId:workingDirectory:) for the full explanation.
        // Same 100ms sleep applies here for the same reason.
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(100))

            let sessionName = self.resolveProjectSessionName(project: project, workingDirectory: workingDirectory)
            self.projectTmuxNames[project] = sessionName

            if FileManager.default.fileExists(atPath: tmuxExecutable) {
                // Snapshot whether this is a pre-existing session before we attach/create it.
                // Used to decide whether to send a git-context init — existing sessions keep
                // their current shell state intact; only fresh sessions get the welcome init.
                let sessionWasNew = !self.isTmuxSessionAlive(named: sessionName)

                tv.startProcess(
                    executable: tmuxExecutable,
                    args: ["new-session", "-A", "-s", sessionName],
                    environment: envList,
                    execName: "tmux",
                    currentDirectory: workingDirectory
                )
                wtLog("[BranchTerminalManager] project tmux '\(sessionName)' \(sessionWasNew ? "created" : "reattached") for \(project)")

                if sessionWasNew {
                    self.initializeProjectSession(name: sessionName, workingDirectory: workingDirectory)
                }
            } else {
                tv.startProcess(
                    executable: "/bin/zsh",
                    args: ["-i"],
                    environment: envList,
                    execName: "zsh",
                    currentDirectory: workingDirectory
                )
            }

            // Apply tmux enhancements to project terminals too
            if FileManager.default.fileExists(atPath: tmuxExecutable) {
                self.enhanceTmuxSession(name: sessionName, branchId: "project-\(project)", workingDirectory: workingDirectory)
            }
        }

        return tv
    }

    /// Send a brief git-context welcome to a freshly created project session.
    /// Only runs for NEW sessions — reattached sessions keep their existing shell state.
    /// Shows git branch + short status (or ls if not a git repo) so the terminal
    /// is immediately useful rather than a blank prompt.
    private func initializeProjectSession(name: String, workingDirectory: String) {
        let tmuxPath = tmuxExecutable
        Task.detached(priority: .utility) {
            // Give the session shell time to fully start before sending keys
            try? await Task.sleep(for: .milliseconds(800))

            // cd ensures correct dir even if tmux ignored currentDirectory,
            // then show git branch + short status (read-only, safe to auto-run).
            let initCmd = "cd '\(workingDirectory)' && git status 2>/dev/null || ls"

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tmuxPath)
            proc.arguments = ["send-keys", "-t", name, initCmd, "Enter"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()

            wtLog("[BranchTerminalManager] Sent git-context init to fresh project session '\(name)'")
        }
    }

    /// Whether a project has an active terminal.
    func isProjectTerminalActive(project: String) -> Bool {
        projectTerminals[project] != nil
    }

    /// tmux session name for a project terminal.
    func projectSessionName(for project: String) -> String? {
        projectTmuxNames[project] ?? canonicalProjectSessionName(for: project)
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

    private static func syntheticProjectSessionName(for project: String) -> String {
        let normalized = project
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return "wt-\(normalized)"
    }

    private func canonicalProjectSessionName(for project: String) -> String {
        if let existing = projectTmuxNames[project] {
            return existing
        }

        let sessionName = Self.syntheticProjectSessionName(for: project)
        projectTmuxNames[project] = sessionName
        return sessionName
    }

    /// Resolve the best existing tmux session for a project working directory before
    /// falling back to a synthetic `wt-*` name. This lets chats reattach to Evan's
    /// real project shell instead of spawning a pristine side-session.
    private func resolveProjectSessionName(project: String, workingDirectory: String) -> String {
        let storedSession = projectTmuxNames[project]
        let storedSessionAlive = storedSession.map(isTmuxSessionAlive(named:)) ?? false

        let candidates: [ProjectSessionCandidate]
        if let storedSession {
            let synthetic = Self.syntheticProjectSessionName(for: project)
            if storedSession == synthetic || !storedSessionAlive {
                candidates = discoverProjectSessionCandidates()
            } else {
                candidates = []
            }
        } else {
            candidates = discoverProjectSessionCandidates()
        }

        let resolved = Self.preferredProjectSessionName(
            project: project,
            for: workingDirectory,
            storedSession: storedSession,
            storedSessionIsAlive: storedSessionAlive,
            candidates: candidates
        )
        projectTmuxNames[project] = resolved

        if let storedSession, storedSession != resolved {
            wtLog("[BranchTerminalManager] Switched project \(project) from '\(storedSession)' to '\(resolved)'")
        } else if storedSession == nil && resolved != Self.syntheticProjectSessionName(for: project) {
            wtLog("[BranchTerminalManager] Reusing existing tmux session '\(resolved)' for project \(project)")
        }

        return resolved
    }

    struct ProjectSessionCandidate {
        let sessionName: String
        let currentPath: String
        let activity: Int
        let currentCommand: String
        let windowCount: Int
    }

    private func discoverProjectSessionCandidates() -> [ProjectSessionCandidate] {
        guard FileManager.default.fileExists(atPath: tmuxExecutable) else { return [] }

        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: tmuxExecutable)
        proc.arguments = [
            "list-panes",
            "-a",
            "-F",
            "#{session_name}||#{pane_current_path}||#{session_activity}||#{pane_current_command}||#{session_windows}"
        ]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            wtLog("[BranchTerminalManager] Failed to probe tmux sessions: \(error)")
            return []
        }

        guard proc.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap { line -> ProjectSessionCandidate? in
                let parts = String(line).components(separatedBy: "||")
                guard parts.count >= 3 else { return nil }
                return ProjectSessionCandidate(
                    sessionName: parts[0],
                    currentPath: parts[1],
                    activity: Int(parts[2]) ?? .max,
                    currentCommand: parts.count > 3 ? parts[3] : "",
                    windowCount: parts.count > 4 ? (Int(parts[4]) ?? 1) : 1
                )
            }
    }

    static func bestProjectSessionMatch(
        project: String,
        for workingDirectory: String,
        candidates: [ProjectSessionCandidate]
    ) -> ProjectSessionCandidate? {
        let normalizedWorkDir = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        let projectSlug = project
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let canonicalName = "wt-\(projectSlug)"

        return candidates
            .filter { candidate in
                !candidate.sessionName.hasPrefix("canvas-") &&
                !candidate.sessionName.hasPrefix("wt-agent-")
            }
            .compactMap { candidate -> (candidate: ProjectSessionCandidate, score: Int)? in
                let normalizedCandidatePath = URL(fileURLWithPath: candidate.currentPath).standardizedFileURL.path
                let relationScore: Int
                if normalizedCandidatePath == normalizedWorkDir {
                    relationScore = 3_000
                } else if normalizedCandidatePath.hasPrefix(normalizedWorkDir + "/") {
                    relationScore = 2_000 + normalizedCandidatePath.count
                } else if normalizedWorkDir.hasPrefix(normalizedCandidatePath + "/") {
                    relationScore = 1_000 + normalizedCandidatePath.count
                } else if candidate.sessionName.caseInsensitiveCompare(project) == .orderedSame {
                    relationScore = 900
                } else {
                    relationScore = 0
                }

                let normalizedSessionName = candidate.sessionName.lowercased()
                let nameScore: Int
                if normalizedSessionName == canonicalName {
                    nameScore = 800
                } else if normalizedSessionName == projectSlug {
                    nameScore = 700
                } else if normalizedSessionName.contains(projectSlug) {
                    nameScore = 350
                } else {
                    nameScore = 0
                }

                guard relationScore > 0 || nameScore >= 700 else {
                    return nil
                }

                let activeCommandScore = Self.isInteractiveShell(candidate.currentCommand) ? 0 : 300
                let windowScore = min(candidate.windowCount, 6) * 35
                let recencyScore = max(0, 500 - min(candidate.activity, 500))
                return (candidate, relationScore + nameScore + activeCommandScore + windowScore + recencyScore)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.candidate.activity != rhs.candidate.activity {
                    return lhs.candidate.activity < rhs.candidate.activity
                }
                return lhs.candidate.sessionName.localizedCaseInsensitiveCompare(rhs.candidate.sessionName) == .orderedAscending
            }
            .first?
            .candidate
    }

    static func preferredProjectSessionName(
        project: String,
        for workingDirectory: String,
        storedSession: String?,
        storedSessionIsAlive: Bool,
        candidates: [ProjectSessionCandidate]
    ) -> String {
        let synthetic = syntheticProjectSessionName(for: project)
        let discovered = bestProjectSessionMatch(
            project: project,
            for: workingDirectory,
            candidates: candidates
        )?.sessionName

        if let storedSession, storedSessionIsAlive {
            if storedSession == synthetic, let discovered, discovered != storedSession {
                return discovered
            }
            return storedSession
        }

        if let discovered {
            return discovered
        }

        return synthetic
    }

    private func isTmuxSessionAlive(named sessionName: String) -> Bool {
        guard FileManager.default.fileExists(atPath: tmuxExecutable) else { return false }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxExecutable)
        proc.arguments = ["has-session", "-t", sessionName]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        // Use a semaphore instead of waitUntilExit(). waitUntilExit() pumps the main run loop,
        // which allows SwiftUI to re-enter AttributeGraph during a render pass → abort().
        // sema.wait() blocks via a kernel wait with no run loop involvement.
        let sema = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sema.signal() }

        do {
            try proc.run()
            sema.wait()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func isInteractiveShell(_ command: String) -> Bool {
        ["zsh", "bash", "fish", "sh", "tmux"].contains(command.lowercased())
    }

    nonisolated static func workspacePathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let normalizedLHS = URL(fileURLWithPath: lhs).standardizedFileURL.path
        let normalizedRHS = URL(fileURLWithPath: rhs).standardizedFileURL.path
        return normalizedLHS == normalizedRHS ||
            normalizedLHS.hasPrefix(normalizedRHS + "/") ||
            normalizedRHS.hasPrefix(normalizedLHS + "/")
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

        // Enhance agent sessions too — env, pipe-pane, monitoring
        if FileManager.default.fileExists(atPath: tmuxExecutable) {
            enhanceTmuxSession(name: sessionName, branchId: "agent-\(jobId)", workingDirectory: workingDirectory)
        }

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

    // MARK: - Session Focus (One-Click Terminal Focus)

    /// Focus a tmux session by agent session ID. Resolves the session to a tmux pane,
    /// selects it, and brings the terminal emulator to front.
    @discardableResult
    func focusSession(agentSessionId: String, workingDirectory: String? = nil) async -> Bool {
        guard FileManager.default.fileExists(atPath: tmuxExecutable) else { return false }

        var targetSession: String?

        // 1. Check branch terminals by working directory
        if let workDir = workingDirectory {
            for (_, name) in tmuxNames {
                if let state = await querySessionState(sessionName: name),
                   Self.workspacePathsMatch(state.currentPath, workDir) {
                    targetSession = name
                    break
                }
            }
        }

        // 2. Check project terminals
        if targetSession == nil {
            for (_, name) in projectTmuxNames {
                if let state = await querySessionState(sessionName: name),
                   workingDirectory == nil || Self.workspacePathsMatch(state.currentPath, workingDirectory!) {
                    targetSession = name
                    break
                }
            }
        }

        // 3. Fallback: list all tmux sessions and match by working directory
        if targetSession == nil, let workDir = workingDirectory {
            targetSession = await findTmuxSessionByPath(workDir)
        }

        guard let sessionName = targetSession else {
            wtLog("[BranchTerminalManager] No tmux session found for agent \(agentSessionId.prefix(8))")
            return false
        }

        let tmuxPath = tmuxExecutable
        let focused = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tmuxPath)
            proc.arguments = ["select-window", "-t", sessionName]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            proc.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus == 0)
            }
            do { try proc.run() } catch { continuation.resume(returning: false) }
        }

        if focused { bringTerminalToFront() }
        return focused
    }

    /// Bring the terminal emulator app to front — prefer Ghostty, then Terminal.app.
    func bringTerminalToFront() {
        let apps = NSWorkspace.shared.runningApplications
        if let ghostty = apps.first(where: { $0.bundleIdentifier == "com.mitchellh.ghostty" }) {
            ghostty.activate()
        } else if let terminal = apps.first(where: { $0.bundleIdentifier == "com.apple.Terminal" }) {
            terminal.activate()
        }
    }

    /// Find a tmux session whose pane working directory matches the given path.
    private func findTmuxSessionByPath(_ path: String) async -> String? {
        let candidates = discoverProjectSessionCandidates()
        return candidates
            .filter { Self.workspacePathsMatch($0.currentPath, path) }
            .sorted { lhs, rhs in
                if lhs.activity != rhs.activity { return lhs.activity < rhs.activity }
                if lhs.windowCount != rhs.windowCount { return lhs.windowCount > rhs.windowCount }
                return lhs.sessionName.localizedCaseInsensitiveCompare(rhs.sessionName) == .orderedAscending
            }
            .first?
            .sessionName
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

    /// Pre-warm the terminal the user should actually see for this chat.
    /// Project-backed conversations always bind to the shared project session.
    func warmUpPreferred(
        branchId: String,
        project: String?,
        workingDirectory: String,
        knownTmuxSession: String? = nil
    ) {
        if let project, !project.isEmpty {
            if let knownTmuxSession, Self.shouldAdoptProjectSession(named: knownTmuxSession) {
                projectTmuxNames[project] = knownTmuxSession
            }
            _ = getOrCreateProjectTerminal(project: project, workingDirectory: workingDirectory)
            if let sessionName = projectTmuxNames[project] {
                persistTmuxSessionName(sessionName, for: branchId)
            } else {
                // Session name is resolved async in getOrCreateProjectTerminal — persist on next turn.
                let capturedBranchId = branchId
                Task { @MainActor [weak self] in
                    guard let self, let sessionName = self.projectTmuxNames[project] else { return }
                    self.persistTmuxSessionName(sessionName, for: capturedBranchId)
                }
            }
            return
        }
        warmUp(branchId: branchId, workingDirectory: workingDirectory, knownTmuxSession: knownTmuxSession)
    }

    private static func shouldAdoptProjectSession(named sessionName: String) -> Bool {
        !sessionName.hasPrefix("canvas-") && !sessionName.hasPrefix("wt-agent-")
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

    /// Verify a tmux session is still alive. If the session exists but the pane's
    /// shell died, respawn it in-place (preserving the session name and mappings).
    /// If the session itself is gone, clean up the stale mapping.
    /// Returns true if the session is valid (or was recovered), false if cleaned up.
    @discardableResult
    func verifySession(branchId: String) async -> Bool {
        guard let sessionName = tmuxNames[branchId],
              FileManager.default.fileExists(atPath: tmuxExecutable) else {
            return false
        }

        let tmuxPath = tmuxExecutable

        // Check if session exists
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
            return false
        }

        // Session exists — check if the pane's shell is still running.
        // If the shell exited (pane-died), respawn it in-place instead of
        // destroying the session and creating a new one.
        let paneAlive = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tmuxPath)
            // list-panes returns non-zero if the pane is dead
            proc.arguments = ["list-panes", "-t", sessionName, "-F", "#{pane_dead}"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice

            proc.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "1"
                // pane_dead = 0 means alive, 1 means dead
                continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(returning: true) // assume alive if we can't check
            }
        }

        if !paneAlive {
            // Respawn the pane — keeps the session name, env vars, pipe-pane, and hooks intact.
            // Much better than kill-session + new-session which loses all configuration.
            let workDir = workingDirs[branchId] ?? FileManager.default.homeDirectoryForCurrentUser.path
            let respawnProc = Process()
            respawnProc.executableURL = URL(fileURLWithPath: tmuxPath)
            respawnProc.arguments = ["respawn-pane", "-t", sessionName, "-k", "-c", workDir]
            respawnProc.standardOutput = FileHandle.nullDevice
            respawnProc.standardError = FileHandle.nullDevice
            do {
                try respawnProc.run()
                respawnProc.waitUntilExit()
                wtLog("[BranchTerminalManager] Respawned dead pane in '\(sessionName)' for \(branchId.prefix(8))")
            } catch {
                wtLog("[BranchTerminalManager] Failed to respawn pane in '\(sessionName)': \(error)")
            }
        }

        return true
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
