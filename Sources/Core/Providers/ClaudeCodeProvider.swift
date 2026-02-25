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
    /// Per-process cancellation tracking — keyed by Process hash so concurrent
    /// sessions don't clobber each other's cancelled state.
    private var _cancelledProcesses = Set<Int>()

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Maps Canvas session IDs to CLI session IDs for --resume support
    private var cliSessionMap: [String: String] = [:]
    /// Tracks when each session was last successfully used (CLI returned output).
    /// Sessions older than this TTL are not resumed — the server has likely expired them.
    private var cliSessionLastUsed: [String: Date] = [:]
    private static let sessionTTL: TimeInterval = 30 * 60  // 30 minutes
    private let mapLock = NSLock()

    /// File-based session map — written synchronously on the parse queue so there
    /// is no async gap between capturing a session ID and it being durable.
    /// Supplements the DB-backed load (which has MainActor/Task timing risks).
    private lazy var sessionMapFileURL: URL = {
        let cortanaDir = URL(fileURLWithPath: home).appendingPathComponent(".cortana")
        try? FileManager.default.createDirectory(at: cortanaDir, withIntermediateDirectories: true)
        return cortanaDir.appendingPathComponent("canvas-sessions.json")
    }()

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
            let resumeGuard = OneShotGuard()

            @Sendable func safeResume(_ value: ProviderHealth) {
                guard resumeGuard.tryFire() else { return }
                continuation.resume(returning: value)
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cliPath)
            proc.arguments = ["--version"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice

            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            env.removeValue(forKey: "CLAUDECODE")
            proc.environment = env

            // 10s timeout — CLI can hang on startup (license check, update prompt)
            let timeoutWork = DispatchWorkItem { [weak proc] in
                if let proc, proc.isRunning { proc.terminate() }
                safeResume(.degraded(reason: "CLI health check timed out"))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(10), execute: timeoutWork)

            proc.terminationHandler = { process in
                timeoutWork.cancel()
                if process.terminationStatus == 0 {
                    safeResume(.available)
                } else {
                    safeResume(.degraded(reason: "CLI exited with status \(process.terminationStatus)"))
                }
            }

            do {
                try proc.run()
            } catch {
                timeoutWork.cancel()
                safeResume(.unavailable(reason: error.localizedDescription))
            }
        }
    }

    // MARK: - Send

    func send(context: ProviderSendContext) -> AsyncStream<BridgeEvent> {
        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.yield(.error("Provider deallocated"))
                continuation.finish()
                return
            }

            let proc = Process()
            let cliPath = "\(home)/.local/bin/claude"
            proc.executableURL = URL(fileURLWithPath: cliPath)

            // Build the message — prepend checkpoint context if session was rotated
            let effectiveMessage: String
            if let checkpoint = context.checkpointContext {
                effectiveMessage = """
                    [Context carried forward from previous session — continue seamlessly]
                    \(checkpoint)

                    [New message]
                    \(context.message)
                    """
            } else {
                effectiveMessage = context.message
            }

            var args = [
                "--output-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--dangerously-skip-permissions",
                "-p", effectiveMessage,
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

            var systemPrompt = CortanaIdentity.cliSystemPrompt(
                project: context.project,
                workingDirectory: context.workingDirectory,
                sessionId: context.sessionId
            )
            // Inject recent conversation history so context survives --resume failures.
            // Server-side sessions can expire silently; this is the fallback.
            if let recentCtx = context.recentContext {
                systemPrompt += "\n\n\(recentCtx)"
            }
            args += ["--append-system-prompt", systemPrompt]

            proc.arguments = args

            if let cwd = context.workingDirectory {
                proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
            } else {
                proc.currentDirectoryURL = URL(fileURLWithPath: "\(home)/Development")
            }

            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            env.removeValue(forKey: "CLAUDECODE")  // prevent nested-session guard from tripping
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(home)/.local/bin:\(home)/.cortana/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
            env["HOME"] = home
            proc.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            // Set both _isRunning and _currentProcess atomically so cancel()
            // can never observe isRunning=true with a nil process handle.
            self.stateLock.lock()
            self._isRunning = true
            self._currentProcess = proc
            self.stateLock.unlock()

            let parser = CLIStreamParser()
            // Track whether any content event was yielded during this run.
            var yieldedContent = false
            var resumeFailedSilently = false
            /// Accumulated stderr — read on termination for diagnostics.
            var stderrData = Data()

            // Read stdout on serial parse queue for ordered access
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }

                self?.parseQueue.async {
                    let events = parser.feed(data)
                    for event in events {
                        // Track content yield so termination handler can detect silent empty runs.
                        if case .text = event { yieldedContent = true }
                        continuation.yield(event)
                    }
                    if let sid = parser.cliSessionId, let self {
                        // Detect silent resume failures: if we asked to resume a session
                        // but got back a different session ID, the CLI started fresh.
                        if let expected = self.getCliSession(for: context.sessionId), expected != sid {
                            canvasLog("[ClaudeCodeProvider] ⚠️ Resume failed silently — new session. Expected: \(expected.prefix(8))…, Got: \(sid.prefix(8))…")
                            resumeFailedSilently = true
                        }
                        self.setCliSession(sid, for: context.sessionId)
                    }
                }
            }

            // Accumulate stderr for diagnostics on failure
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stderrData.append(data) }
            }

            // Process termination on same serial queue for ordering
            proc.terminationHandler = { [weak self] process in
                self?.parseQueue.async {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let remaining = parser.flush()
                    for event in remaining {
                        if case .text = event { yieldedContent = true }
                        continuation.yield(event)
                    }

                    // Capture stderr for logging
                    let stderrText = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !stderrText.isEmpty {
                        canvasLog("[ClaudeCodeProvider] stderr: \(stderrText.prefix(500))")
                    }

                    let procHash = ObjectIdentifier(process).hashValue
                    let wasCancelled: Bool = {
                        self?.stateLock.lock()
                        defer { self?.stateLock.unlock() }
                        let cancelled = self?._cancelledProcesses.contains(procHash) ?? false
                        self?._cancelledProcesses.remove(procHash)
                        return cancelled
                    }()

                    if let sid = parser.cliSessionId, let self {
                        self.setCliSession(sid, for: context.sessionId)
                        Task { @MainActor [weak self] in
                            self?.persistSessionMap()
                        }
                    } else if !wasCancelled {
                        // No session ID and not cancelled — session is broken.
                        // Rotate so next attempt starts fresh instead of resume-looping.
                        canvasLog("[ClaudeCodeProvider] ⚠️ Process exited without a session ID — rotating session")
                        self?.rotateSession(for: context.sessionId)
                    }

                    if process.terminationStatus != 0 && !parser.isError && !wasCancelled {
                        // Non-zero exit that wasn't intentional cancellation.
                        // Rotate the session so the next message starts clean
                        // instead of trying to --resume a dead session.
                        self?.rotateSession(for: context.sessionId)

                        // Surface stderr if available — it's the actual reason.
                        let reason: String
                        if !stderrText.isEmpty {
                            reason = stderrText.prefix(200).description
                        } else if process.terminationStatus == 15 {
                            reason = "Connection interrupted"
                        } else {
                            reason = "CLI exited with status \(process.terminationStatus)"
                        }
                        canvasLog("[ClaudeCodeProvider] CLI failed: status=\(process.terminationStatus), stderr=\(stderrText.prefix(200))")
                        continuation.yield(.error("\(reason). Send another message to continue."))
                    } else if !yieldedContent && resumeFailedSilently {
                        // Resume silently started a new session but produced no content.
                        // Surface as an error so the caller can retry or surface to the user.
                        canvasLog("[ClaudeCodeProvider] ⚠️ Resume fallback produced no content — surfacing error")
                        continuation.yield(.error("Session resume failed and retry produced no response. Please try again."))
                    }

                    var usage = SessionTokenUsage()
                    usage.totalInputTokens = parser.inputTokens
                    usage.totalOutputTokens = parser.outputTokens
                    usage.turnCount = parser.numTurns
                    continuation.yield(.done(usage: usage))
                    continuation.finish()

                    self?.stateLock.lock()
                    self?._isRunning = false
                    self?._currentProcess = nil
                    self?.stateLock.unlock()
                }
            }

            // Capture proc directly so cancelling this stream only terminates *this* CLI
            // process. Using self?.cancel() was a bug: concurrent sends overwrote
            // _currentProcess, so cancelling stream-1 would kill stream-2's process.
            continuation.onTermination = { _ in
                proc.terminate()
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

    // MARK: - Session Rotation

    /// Clear the CLI session mapping for a Canvas session.
    /// Next send() will start a fresh CLI session instead of resuming.
    func rotateSession(for canvasSessionId: String) {
        mapLock.lock()
        cliSessionMap.removeValue(forKey: canvasSessionId)
        cliSessionLastUsed.removeValue(forKey: canvasSessionId)
        mapLock.unlock()
        canvasLog("[ClaudeCodeProvider] Rotated session mapping for \(canvasSessionId)")
    }

    // MARK: - Cancel

    func cancel() {
        stateLock.lock()
        let proc = _currentProcess
        if let proc {
            _cancelledProcesses.insert(ObjectIdentifier(proc).hashValue)
        }
        _currentProcess = nil
        _isRunning = false
        stateLock.unlock()
        proc?.terminate()
    }

    // MARK: - Session Map

    private func getCliSession(for canvasSessionId: String) -> String? {
        mapLock.lock()
        defer { mapLock.unlock() }
        guard let sid = cliSessionMap[canvasSessionId] else { return nil }
        // Don't resume sessions that are likely expired on the server.
        // No timestamp = loaded from DB/file with unknown age = treat as stale.
        guard let lastUsed = cliSessionLastUsed[canvasSessionId] else {
            canvasLog("[ClaudeCodeProvider] Session \(sid.prefix(8))… has no timestamp — starting fresh")
            return nil
        }
        if Date().timeIntervalSince(lastUsed) > Self.sessionTTL {
            canvasLog("[ClaudeCodeProvider] Session \(sid.prefix(8))… expired (>\(Int(Self.sessionTTL/60))min) — starting fresh")
            return nil
        }
        return sid
    }

    private func setCliSession(_ cliSessionId: String, for canvasSessionId: String) {
        mapLock.lock()
        cliSessionMap[canvasSessionId] = cliSessionId
        cliSessionLastUsed[canvasSessionId] = Date()
        let snapshot = cliSessionMap
        mapLock.unlock()
        // Write to file synchronously — no MainActor/Task timing risk.
        // This runs on parseQueue, which is fine for file I/O.
        writeSessionMapFile(snapshot)
    }

    private func writeSessionMapFile(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: sessionMapFileURL, options: .atomic)
    }

    @MainActor
    private func loadSessionMap() {
        // Load from DB first (baseline)
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
            canvasLog("[ClaudeCodeProvider] Failed to load session map from DB: \(error)")
        }

        // Overlay with file — file is written synchronously on every update so
        // it's always more current than the DB (which goes via async MainActor task).
        if let data = try? Data(contentsOf: sessionMapFileURL),
           let fileMap = try? JSONDecoder().decode([String: String].self, from: data) {
            mapLock.lock()
            for (canvasId, cliId) in fileMap {
                cliSessionMap[canvasId] = cliId  // file wins over DB
            }
            mapLock.unlock()
            canvasLog("[ClaudeCodeProvider] Overlaid \(fileMap.count) session mappings from file")
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
