import Foundation
import GRDB

// MARK: - Claude Code Provider

/// Primary LLM provider using the Claude CLI with Max subscription.
/// Spawns `claude -p <message> --output-format stream-json` and parses the structured
/// event stream into BridgeEvents. Costs $0 against Max subscription by stripping
/// ANTHROPIC_API_KEY from the environment.
final class ClaudeCodeProvider: LLMProvider {
    let displayName = "Claude Code (Max)"
    let identifier = "claude-code"
    let capabilities: ProviderCapabilities = [
        .streaming, .toolExecution, .sessionResume, .sessionFork, .modelSelection
    ]

    /// Thread-safe state lock for isRunning + currentProcess
    private let stateLock = NSLock()
    private var _isRunning = false
    private var _currentProcess: Process?

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Maps Canvas session IDs to CLI session IDs for --resume support
    private var cliSessionMap: [String: String] = [:]
    private let mapLock = NSLock()

    /// Serial queue for parser access (readabilityHandler + terminationHandler ordering)
    private let parseQueue = DispatchQueue(label: "com.cortana.canvas.cli-parser")

    init() {
        Task { @MainActor [weak self] in
            self?.loadSessionMap()
        }
    }

    // MARK: - Health Check

    func checkHealth() async -> ProviderHealth {
        let cliPath = "\(home)/.local/bin/claude"
        guard FileManager.default.fileExists(atPath: cliPath) else {
            return .unavailable(reason: "Claude CLI not found at \(cliPath)")
        }

        return await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cliPath)
            proc.arguments = ["--version"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice

            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            proc.environment = env

            proc.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .available)
                } else {
                    continuation.resume(returning: .degraded(reason: "CLI exited with status \(process.terminationStatus)"))
                }
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(returning: .unavailable(reason: error.localizedDescription))
            }
        }
    }

    // MARK: - Send

    func send(context: ProviderSendContext) -> AsyncStream<BridgeEvent> {
        stateLock.lock()
        _isRunning = true
        stateLock.unlock()

        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.yield(.error("Provider deallocated"))
                continuation.finish()
                return
            }

            let proc = Process()
            let cliPath = "\(home)/.local/bin/claude"
            proc.executableURL = URL(fileURLWithPath: cliPath)

            var args = [
                "--output-format", "stream-json",
                "--verbose",
                "--dangerously-skip-permissions",
                "-p", context.message,
            ]

            if let model = context.model {
                args += ["--model", model]
            }

            let cliSessionId = self.getCliSession(for: context.sessionId)
            if let cliSid = cliSessionId, !context.isNewSession {
                args += ["--resume", cliSid]
            }

            if context.isNewSession, let parentSessionId = context.parentSessionId {
                if let parentCliSid = self.getCliSession(for: parentSessionId) {
                    args += ["--resume", parentCliSid, "--fork-session"]
                }
            }

            let systemPrompt = CortanaIdentity.cliSystemPrompt(
                project: context.project,
                workingDirectory: context.workingDirectory
            )
            args += ["--append-system-prompt", systemPrompt]

            proc.arguments = args

            if let cwd = context.workingDirectory {
                proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
            } else {
                proc.currentDirectoryURL = URL(fileURLWithPath: "\(home)/Development")
            }

            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(home)/.local/bin:\(home)/.cortana/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
            env["HOME"] = home
            proc.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            self.stateLock.lock()
            self._currentProcess = proc
            self.stateLock.unlock()

            let parser = CLIStreamParser()

            // Read stdout on serial parse queue for ordered access
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }

                self?.parseQueue.async {
                    let events = parser.feed(data)
                    for event in events {
                        continuation.yield(event)
                    }
                    if let sid = parser.cliSessionId, let self {
                        self.setCliSession(sid, for: context.sessionId)
                    }
                }
            }

            // Process termination on same serial queue for ordering
            proc.terminationHandler = { [weak self] process in
                self?.parseQueue.async {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil

                    let remaining = parser.flush()
                    for event in remaining {
                        continuation.yield(event)
                    }

                    if let sid = parser.cliSessionId, let self {
                        self.setCliSession(sid, for: context.sessionId)
                        Task { @MainActor [weak self] in
                            self?.persistSessionMap()
                        }
                    }

                    if process.terminationStatus != 0 && !parser.isError {
                        continuation.yield(.error("CLI exited with status \(process.terminationStatus)"))
                    }

                    let usage = SessionTokenUsage()
                    continuation.yield(.done(usage: usage))
                    continuation.finish()

                    self?.stateLock.lock()
                    self?._isRunning = false
                    self?._currentProcess = nil
                    self?.stateLock.unlock()
                }
            }

            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }

            do {
                try proc.run()
                canvasLog("[ClaudeCodeProvider] CLI launched: session=\(context.sessionId), resume=\(cliSessionId ?? "none")")
            } catch {
                canvasLog("[ClaudeCodeProvider] Failed to launch CLI: \(error)")
                continuation.yield(.error("Failed to launch Claude CLI: \(error.localizedDescription)"))
                continuation.finish()
                self.stateLock.lock()
                self._isRunning = false
                self._currentProcess = nil
                self.stateLock.unlock()
            }
        }
    }

    // MARK: - Cancel

    func cancel() {
        stateLock.lock()
        let proc = _currentProcess
        _currentProcess = nil
        _isRunning = false
        stateLock.unlock()
        proc?.terminate()
    }

    // MARK: - Session Map

    private func getCliSession(for canvasSessionId: String) -> String? {
        mapLock.lock()
        defer { mapLock.unlock() }
        return cliSessionMap[canvasSessionId]
    }

    private func setCliSession(_ cliSessionId: String, for canvasSessionId: String) {
        mapLock.lock()
        defer { mapLock.unlock() }
        cliSessionMap[canvasSessionId] = cliSessionId
    }

    @MainActor
    private func loadSessionMap() {
        do {
            let rows = try DatabaseManager.shared.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT canvas_session_id, cli_session_id FROM canvas_cli_sessions WHERE provider = 'claude-code'"
                )
            }
            mapLock.lock()
            for row in rows {
                if let canvasId: String = row["canvas_session_id"],
                   let cliId: String = row["cli_session_id"] {
                    cliSessionMap[canvasId] = cliId
                }
            }
            mapLock.unlock()
            canvasLog("[ClaudeCodeProvider] Loaded \(rows.count) session mappings from DB")
        } catch {
            canvasLog("[ClaudeCodeProvider] Failed to load session map: \(error)")
        }
    }

    @MainActor
    private func persistSessionMap() {
        mapLock.lock()
        let snapshot = cliSessionMap
        mapLock.unlock()

        do {
            try DatabaseManager.shared.write { db in
                for (canvasId, cliId) in snapshot {
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO canvas_cli_sessions
                            (canvas_session_id, cli_session_id, provider, updated_at)
                            VALUES (?, ?, 'claude-code', datetime('now'))
                            """,
                        arguments: [canvasId, cliId]
                    )
                }
            }
        } catch {
            canvasLog("[ClaudeCodeProvider] Failed to persist session map: \(error)")
        }
    }
}
