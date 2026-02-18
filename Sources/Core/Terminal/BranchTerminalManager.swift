import Foundation
import SwiftTerm

// MARK: - BranchTerminalManager

/// Singleton that owns one persistent PTY terminal per conversation branch.
///
/// Terminal processes survive view hide/show — switching branches doesn't kill the shell.
/// Chat execution is mirrored to the active branch's terminal so the user sees everything
/// Claude does in real time, and can take over or type alongside Claude at any moment.
@MainActor
final class BranchTerminalManager: ObservableObject {
    static let shared = BranchTerminalManager()

    /// branchId → live LocalProcessTerminalView (NSView held here, not in the view hierarchy)
    private var terminals: [String: LocalProcessTerminalView] = [:]

    /// Working directory per branch (for re-use if view recreates)
    private var workingDirs: [String: String] = [:]

    private init() {}

    // MARK: - Terminal Lifecycle

    /// Returns the existing terminal for this branch, or spawns a new one.
    /// Safe to call repeatedly — returns the same instance every time.
    func getOrCreate(branchId: String, workingDirectory: String) -> LocalProcessTerminalView {
        if let existing = terminals[branchId] { return existing }

        let frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        let tv = LocalProcessTerminalView(frame: frame)

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")   // prevent nested-session guard
        env["TERM"] = "xterm-256color"

        tv.startProcess(
            executable: "/bin/zsh",
            args: ["-i"],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: "zsh",
            currentDirectory: workingDirectory
        )

        terminals[branchId] = tv
        workingDirs[branchId] = workingDirectory
        canvasLog("[BranchTerminalManager] Spawned terminal for \(branchId.prefix(8)) at \(workingDirectory)")
        return tv
    }

    /// Whether a branch has an active terminal process.
    func isActive(branchId: String) -> Bool {
        terminals[branchId] != nil
    }

    // MARK: - PTY Input

    /// Write text to the branch's PTY stdin — appears exactly as if the user typed it.
    /// Use this to mirror Claude's tokens and tool events into the terminal in real time.
    func send(to branchId: String, text: String) {
        guard let tv = terminals[branchId] else { return }
        let bytes = ArraySlice(Array(text.utf8))
        tv.send(source: tv, data: bytes)
    }

    // MARK: - Lifecycle Management

    /// Pre-warm a terminal for a newly created branch (called from TreeStore or UI layer).
    func warmUp(branchId: String, workingDirectory: String) {
        _ = getOrCreate(branchId: branchId, workingDirectory: workingDirectory)
    }

    /// Terminate a branch's terminal process (branch archived or deleted).
    func terminate(branchId: String) {
        terminals[branchId]?.terminate()
        terminals.removeValue(forKey: branchId)
        workingDirs.removeValue(forKey: branchId)
        canvasLog("[BranchTerminalManager] Terminated terminal for \(branchId.prefix(8))")
    }

    /// Terminate all terminals (app quit).
    func terminateAll() {
        for (_, tv) in terminals { tv.terminate() }
        terminals.removeAll()
        workingDirs.removeAll()
    }
}
