import Foundation
import GRDB

// MARK: - Dispatch Origin

/// Where a programmatic dispatch request originated.
enum DispatchOrigin: String, Sendable {
    case background     // Command Center / UI initiated
    case gateway        // Gateway API (/v1/cortana/dispatch)
    case crew           // Starfleet crew delegation
    case ui             // User explicit "dispatch" action
}

// MARK: - Dispatch Context

/// Everything needed to fire a programmatic dispatch through the Agent SDK.
struct DispatchContext: Sendable {
    let message: String
    let project: String
    let workingDirectory: String
    let model: String?
    let branchId: String?
    let origin: DispatchOrigin
    let allowedTools: [String]?
    let skipPermissions: Bool
    let systemPromptOverride: String?
}

// MARK: - Agent SDK Provider

/// Programmatic dispatch provider using Claude CLI's Agent SDK wire protocol.
///
/// Key differences from ClaudeCodeProvider:
/// - **Per-dispatch isolation**: Each dispatch gets its own Process. No shared session state.
/// - **Structured result collection**: Accumulates full response text + token usage.
/// - **Fire-and-forget**: No session resume, no TTLs, no rotation. Start → run → done.
/// - **DB-tracked**: Every dispatch is recorded in `canvas_dispatches` for the Command Center.
///
/// Reuses `CLIStreamParser` (identical) and `BridgeEvent` (universal event type).
final class AgentSDKProvider: LLMProvider {
    let displayName = "Agent SDK (Background)"
    let identifier = "agent-sdk"
    let capabilities: ProviderCapabilities = [
        .streaming, .toolExecution, .modelSelection
    ]

    /// Thread-safe tracking of all active dispatch processes
    private let stateLock = NSLock()
    private var activeProcesses: [String: Process] = [:]
    private var cancelledDispatchIds: Set<String> = []

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !activeProcesses.isEmpty
    }

    // MARK: - Health Check

    func checkHealth() async -> ProviderHealth {
        let cliPath = "\(home)/.local/bin/claude"
        guard FileManager.default.fileExists(atPath: cliPath) else {
            return .unavailable(reason: "Claude CLI not found")
        }
        return .available
    }

    // MARK: - LLMProvider Send (not used directly — use dispatch() instead)

    func send(context: ProviderSendContext) -> AsyncStream<BridgeEvent> {
        // AgentSDKProvider is invoked through dispatch(), not the normal send() path.
        // This implementation exists to satisfy the LLMProvider protocol.
        let dispatchCtx = DispatchContext(
            message: context.message,
            project: context.project ?? "unknown",
            workingDirectory: context.workingDirectory ?? home,
            model: context.model,
            branchId: context.branchId,
            origin: .ui,
            allowedTools: nil,
            skipPermissions: true,
            systemPromptOverride: nil
        )
        return dispatch(context: dispatchCtx).stream
    }

    func cancel() {
        stateLock.lock()
        let processes = activeProcesses
        cancelledDispatchIds.formUnion(processes.keys)
        activeProcesses.removeAll()
        stateLock.unlock()

        for (_, proc) in processes {
            proc.terminate()
        }
    }

    // MARK: - Dispatch

    /// Fire a programmatic dispatch. Returns the dispatch ID and a stream of BridgeEvents.
    /// The dispatch is tracked in `canvas_dispatches` for the Command Center.
    func dispatch(context: DispatchContext) -> (id: String, stream: AsyncStream<BridgeEvent>) {
        let dispatchId = UUID().uuidString

        let stream = AsyncStream<BridgeEvent> { [weak self] continuation in
            guard let self else {
                continuation.yield(.error("Provider deallocated"))
                continuation.finish()
                return
            }

            // Create dispatch record
            let record = WorldTreeDispatch(
                id: dispatchId,
                project: context.project,
                branchId: context.branchId,
                message: context.message,
                model: context.model,
                status: .queued,
                workingDirectory: context.workingDirectory,
                origin: context.origin.rawValue
            )
            self.persistDispatch(record)

            // Register with output stream store for live tailing
            let projectName = context.project
            let message = context.message
            Task { @MainActor in
                JobOutputStreamStore.shared.beginStream(
                    id: dispatchId,
                    kind: .dispatch,
                    command: message,
                    project: projectName
                )
            }

            let proc = Process()
            let cliPath = "\(self.home)/.local/bin/claude"
            proc.executableURL = URL(fileURLWithPath: cliPath)

            var args = [
                "--output-format", "stream-json",
                "--verbose",
                "-p", context.message,
            ]

            if let model = context.model {
                args += ["--model", model]
            }

            if context.skipPermissions {
                args += ["--dangerously-skip-permissions"]
            }

            if let tools = context.allowedTools, !tools.isEmpty {
                for tool in tools {
                    args += ["--allowedTools", tool]
                }
            }

            // Build system prompt for dispatch context
            let systemPrompt = context.systemPromptOverride ?? CortanaIdentity.cliSystemPrompt(
                project: context.project,
                workingDirectory: context.workingDirectory
            )
            args += ["--append-system-prompt", systemPrompt]

            proc.arguments = args

            if FileManager.default.fileExists(atPath: context.workingDirectory) {
                proc.currentDirectoryURL = URL(fileURLWithPath: context.workingDirectory)
            } else {
                proc.currentDirectoryURL = URL(fileURLWithPath: "\(self.home)/Development")
            }

            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            env.removeValue(forKey: "CLAUDECODE")
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(self.home)/.local/bin:\(self.home)/.cortana/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
            env["HOME"] = self.home
            proc.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            // Track process
            self.stateLock.lock()
            self.activeProcesses[dispatchId] = proc
            self.stateLock.unlock()

            // Mark as running — capture start time for duration calculation in terminationHandler
            let dispatchStartTime = Date()
            self.updateDispatchStatus(dispatchId, status: .running, startedAt: dispatchStartTime)

            let parser = CLIStreamParser()
            let parseQueue = DispatchQueue(label: "com.cortana.canvas.sdk-dispatch.\(dispatchId)")
            var accumulatedText = ""
            var stderrData = Data()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }

                parseQueue.async {
                    let events = parser.feed(data)
                    for event in events {
                        if case .text(let chunk) = event {
                            accumulatedText += chunk
                            // Publish to live output stream store
                            Task { @MainActor in
                                JobOutputStreamStore.shared.appendOutput(id: dispatchId, chunk: chunk)
                            }
                        }
                        continuation.yield(event)
                    }
                }
            }

            // Route stderr to parseQueue to avoid data race with terminationHandler
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                parseQueue.async {
                    stderrData.append(data)
                }
            }

            proc.terminationHandler = { [weak self] process in
                parseQueue.async {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let remaining = parser.flush()
                    for event in remaining {
                        if case .text(let chunk) = event {
                            accumulatedText += chunk
                        }
                        continuation.yield(event)
                    }

                    let stderrText = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    // Determine final status — cancelled dispatches skip fail/complete
                    let projectName = context.project
                    let duration = Date().timeIntervalSince(dispatchStartTime)

                    if let strongSelf = self {
                        strongSelf.stateLock.lock()
                        let wasCancelled = strongSelf.cancelledDispatchIds.contains(dispatchId)
                        strongSelf.stateLock.unlock()

                        if wasCancelled {
                            strongSelf.updateDispatchStatus(dispatchId, status: .cancelled)
                            Task { @MainActor in
                                JobOutputStreamStore.shared.endStream(id: dispatchId, status: "cancelled")
                            }
                        } else if process.terminationStatus == 0 {
                            strongSelf.completeDispatch(
                                dispatchId,
                                resultText: accumulatedText,
                                tokensIn: parser.inputTokens,
                                tokensOut: parser.outputTokens,
                                cliSessionId: parser.cliSessionId
                            )
                            strongSelf.recordMetrics(
                                project: projectName,
                                isSuccess: true,
                                tokensIn: parser.inputTokens,
                                tokensOut: parser.outputTokens,
                                duration: duration
                            )
                            Task { @MainActor in
                                JobOutputStreamStore.shared.endStream(id: dispatchId, status: "completed")
                            }
                        } else {
                            let errorMsg = !stderrText.isEmpty
                                ? String(stderrText.prefix(500))
                                : "CLI exited with status \(process.terminationStatus)"
                            strongSelf.failDispatch(dispatchId, error: errorMsg)
                            strongSelf.recordMetrics(
                                project: projectName,
                                isSuccess: false,
                                tokensIn: parser.inputTokens,
                                tokensOut: parser.outputTokens,
                                duration: duration
                            )
                            continuation.yield(.error(errorMsg))
                            Task { @MainActor in
                                JobOutputStreamStore.shared.endStream(id: dispatchId, status: "failed", error: errorMsg)
                            }
                        }

                        // Remove from active tracking
                        strongSelf.stateLock.lock()
                        strongSelf.activeProcesses.removeValue(forKey: dispatchId)
                        strongSelf.cancelledDispatchIds.remove(dispatchId)
                        strongSelf.stateLock.unlock()
                    }

                    var usage = SessionTokenUsage()
                    usage.totalInputTokens = parser.inputTokens
                    usage.totalOutputTokens = parser.outputTokens
                    usage.turnCount = parser.numTurns
                    continuation.yield(.done(usage: usage))
                    continuation.finish()

                    wtLog("[AgentSDK] dispatch \(dispatchId.prefix(8)) finished: status=\(process.terminationStatus), tokens=\(parser.inputTokens)+\(parser.outputTokens)")
                }
            }

            continuation.onTermination = { [weak self] _ in
                self?.stateLock.lock()
                self?.cancelledDispatchIds.insert(dispatchId)
                self?.stateLock.unlock()
                proc.terminate()
            }

            do {
                try proc.run()
                wtLog("[AgentSDK] dispatch \(dispatchId.prefix(8)) launched: project=\(context.project), model=\(context.model ?? "default")")
            } catch {
                wtLog("[AgentSDK] dispatch \(dispatchId.prefix(8)) failed to launch: \(error)")
                self.failDispatch(dispatchId, error: error.localizedDescription)
                continuation.yield(.error("Failed to launch: \(error.localizedDescription)"))
                continuation.finish()
                self.stateLock.lock()
                self.activeProcesses.removeValue(forKey: dispatchId)
                self.stateLock.unlock()
            }
        }
        return (id: dispatchId, stream: stream)
    }

    // MARK: - Cancel Specific Dispatch

    /// Cancel a specific dispatch by ID.
    /// Marks as cancelled in the tracking set; terminationHandler writes the final DB status.
    func cancelDispatch(_ dispatchId: String) {
        stateLock.lock()
        cancelledDispatchIds.insert(dispatchId)
        let proc = activeProcesses.removeValue(forKey: dispatchId)
        stateLock.unlock()

        proc?.terminate()
    }

    /// Check if a specific dispatch is still running
    func isDispatchActive(_ dispatchId: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeProcesses[dispatchId] != nil
    }

    /// All currently active dispatch IDs
    var activeDispatchIds: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(activeProcesses.keys)
    }

    // MARK: - DB Persistence
    // Fire-and-forget DB updates via MainActor hop — same pattern as ClaudeCodeProvider.

    private func persistDispatch(_ dispatch: WorldTreeDispatch) {
        let d = dispatch
        Task { @MainActor in
            do {
                try DatabaseManager.shared.write { db in try d.insert(db) }
            } catch {
                wtLog("[AgentSDK] Failed to persist dispatch: \(error)")
            }
        }
    }

    private func updateDispatchStatus(_ id: String, status: WorldTreeDispatch.DispatchStatus, startedAt: Date? = nil) {
        let statusRaw = status.rawValue
        Task { @MainActor in
            do {
                try DatabaseManager.shared.write { db in
                    if let start = startedAt {
                        try db.execute(
                            sql: "UPDATE canvas_dispatches SET status = ?, started_at = ? WHERE id = ?",
                            arguments: [statusRaw, start, id]
                        )
                    } else {
                        try db.execute(
                            sql: "UPDATE canvas_dispatches SET status = ? WHERE id = ?",
                            arguments: [statusRaw, id]
                        )
                    }
                }
            } catch {
                wtLog("[AgentSDK] Failed to update dispatch \(id.prefix(8)): \(error)")
            }
        }
    }

    private func completeDispatch(_ id: String, resultText: String, tokensIn: Int, tokensOut: Int, cliSessionId: String?) {
        Task { @MainActor in
            do {
                try DatabaseManager.shared.write { db in
                    try db.execute(
                        sql: """
                            UPDATE canvas_dispatches
                            SET status = 'completed', result_text = ?, result_tokens_in = ?,
                                result_tokens_out = ?, cli_session_id = ?, completed_at = datetime('now')
                            WHERE id = ?
                            """,
                        arguments: [resultText, tokensIn, tokensOut, cliSessionId, id]
                    )
                }
            } catch {
                wtLog("[AgentSDK] Failed to complete dispatch \(id.prefix(8)): \(error)")
            }
        }
    }

    private func failDispatch(_ id: String, error errorMsg: String) {
        Task { @MainActor in
            do {
                try DatabaseManager.shared.write { db in
                    try db.execute(
                        sql: """
                            UPDATE canvas_dispatches
                            SET status = 'failed', error = ?, completed_at = datetime('now')
                            WHERE id = ?
                            """,
                        arguments: [errorMsg, id]
                    )
                }
            } catch {
                wtLog("[AgentSDK] Failed to mark dispatch \(id.prefix(8)) as failed: \(error)")
            }
        }
    }

    /// Record per-project metrics directly from dispatch data (avoids DB read race with completeDispatch).
    private func recordMetrics(project: String, isSuccess: Bool, tokensIn: Int, tokensOut: Int, duration: TimeInterval) {
        Task { @MainActor in
            do {
                try DatabaseManager.shared.write { db in
                    try db.execute(
                        sql: """
                            INSERT INTO canvas_project_metrics
                            (project, total_dispatches, successful_dispatches, failed_dispatches,
                             total_tokens_in, total_tokens_out, total_duration_seconds,
                             last_activity_at, updated_at)
                            VALUES (?, 1, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))
                            ON CONFLICT(project) DO UPDATE SET
                                total_dispatches = total_dispatches + 1,
                                successful_dispatches = successful_dispatches + ?,
                                failed_dispatches = failed_dispatches + ?,
                                total_tokens_in = total_tokens_in + ?,
                                total_tokens_out = total_tokens_out + ?,
                                total_duration_seconds = total_duration_seconds + ?,
                                last_activity_at = datetime('now'),
                                updated_at = datetime('now')
                            """,
                        arguments: [
                            project,
                            isSuccess ? 1 : 0, isSuccess ? 0 : 1,
                            tokensIn, tokensOut, duration,
                            isSuccess ? 1 : 0, isSuccess ? 0 : 1,
                            tokensIn, tokensOut, duration
                        ]
                    )
                }
            } catch {
                wtLog("[AgentSDK] Failed to record metrics: \(error)")
            }
        }
    }
}
