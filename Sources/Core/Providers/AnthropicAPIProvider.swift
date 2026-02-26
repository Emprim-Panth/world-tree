import Foundation

// MARK: - Anthropic API Provider

/// Secondary LLM provider using the direct Anthropic Messages API.
/// Extracted from ClaudeBridge — owns AnthropicClient, ConversationStateManager,
/// ToolExecutor, and KB query logic. Requires API credits.
final class AnthropicAPIProvider: LLMProvider {
    let displayName = "Anthropic API (Direct)"
    let identifier = "anthropic-api"
    let capabilities: ProviderCapabilities = [
        .streaming, .toolExecution, .sessionResume, .sessionFork,
        .promptCaching, .costTracking, .modelSelection
    ]

    private let stateLock = NSLock()
    private var _isRunning = false
    private(set) var isRunning: Bool {
        get { stateLock.withLock { _isRunning } }
        set { stateLock.withLock { _isRunning = newValue } }
    }

    private let apiClient: AnthropicClient
    private var stateManager: ConversationStateManager?
    private var currentTask: Task<Void, Never>?
    private var _isCancelled = false
    private var isCancelled: Bool {
        get { stateLock.withLock { _isCancelled } }
        set { stateLock.withLock { _isCancelled = newValue } }
    }

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let maxToolLoopIterations = 25

    /// Resolved bun executable — searched at startup from common install locations.
    private static let bunExecutable: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/bun",          // Apple Silicon Homebrew
            "/usr/local/bin/bun",              // Intel Homebrew
            "\(home)/.bun/bin/bun",            // bun install default
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? "/opt/homebrew/bin/bun"
    }()

    init(apiKey: String) {
        self.apiClient = AnthropicClient(apiKey: apiKey)
    }

    // MARK: - Health Check

    func checkHealth() async -> ProviderHealth {
        // A key being present doesn't guarantee validity, but absent means all requests will fail.
        let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        if !envKey.isEmpty { return .available }
        let keyFile = "\(home)/.anthropic/api_key"
        let fileKey = (try? String(contentsOfFile: keyFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        guard !fileKey.isEmpty else {
            return .unavailable(reason: "Anthropic API key not configured")
        }
        return .available
    }

    // MARK: - Send

    func send(context: ProviderSendContext) -> AsyncStream<BridgeEvent> {
        isCancelled = false
        isRunning = true
        WakeLock.shared.acquire()

        return AsyncStream { [weak self] continuation in
            guard let self else {
                WakeLock.shared.release()
                continuation.yield(.error("Provider deallocated"))
                continuation.finish()
                return
            }

            self.currentTask = Task { @MainActor [weak self] in
                guard let self else { return }

                do {
                    wtLog("[AnthropicAPIProvider] send() started for session=\(context.sessionId)")

                    let state = try await self.getOrCreateStateManager(context: context)
                    wtLog("[AnthropicAPIProvider] state manager ready, system blocks=\(state.systemBlocks.count)")

                    // Refresh terminal context (captures latest PTY output before each message)
                    state.refreshTerminalContext()

                    // Query KB (async — runs off MainActor during process wait)
                    let kbContext = await self.queryKnowledgeBase(message: context.message)
                    state.appendKBContext(kbContext)

                    // Add user message (with any image/file attachments)
                    state.addUserMessage(context.message, attachments: context.attachments)

                    let selectedModel = context.model ?? AppConstants.defaultModel
                    let cwd = resolveWorkingDirectory(context.workingDirectory, project: context.project)
                    // Pass the branch's tmux session name so bash tool calls run visibly in the terminal
                    let tmuxSession = BranchTerminalManager.shared.sessionName(for: context.branchId)
                    let executor = ToolExecutor(
                        workingDirectory: URL(fileURLWithPath: cwd),
                        tmuxSessionName: tmuxSession,
                        sessionId: context.sessionId
                    )
                    var cumulativeUsage = TokenUsage.zero

                    // Tool loop
                    for _ in 0..<self.maxToolLoopIterations {
                        if self.isCancelled { break }

                        // Extended thinking configuration:
                        // - Opus 4.6+: adaptive mode (model decides when/how much to think)
                        // - Sonnet/other: manual 10K budget
                        // Max tokens raised to 32K when thinking is active (budget counts against it).
                        let thinkingConfig: ThinkingConfig? = context.extendedThinking
                            ? (selectedModel.contains("opus") ? .adaptive() : .enabled(budgetTokens: 10_000))
                            : nil
                        let maxTokens = context.extendedThinking ? 32_000 : 16_384

                        let request = AnthropicRequest(
                            model: selectedModel,
                            maxTokens: maxTokens,
                            system: state.systemBlocks,
                            tools: WorldTreeTools.definitions(),
                            messages: state.messagesForAPI(),
                            stream: true,
                            thinking: thinkingConfig
                        )

                        var textAccumulator = ""
                        var toolUseBlocks: [ContentBlock.ToolUseBlock] = []
                        var currentToolId: String?
                        var currentToolName: String?
                        var currentToolInputJSON = ""
                        var stopReason: String?

                        let stream = self.apiClient.stream(request: request)

                        for try await event in stream {
                            if self.isCancelled { break }

                            switch event {
                            case .messageStart(let payload):
                                cumulativeUsage.add(payload.message.usage)

                            case .contentBlockStart(let payload):
                                if payload.contentBlock.type == "tool_use" {
                                    currentToolId = payload.contentBlock.id
                                    currentToolName = payload.contentBlock.name
                                    currentToolInputJSON = ""
                                }

                            case .contentBlockDelta(let payload):
                                switch payload.delta {
                                case .textDelta(let text):
                                    textAccumulator += text
                                    continuation.yield(.text(text))
                                case .inputJsonDelta(let json):
                                    currentToolInputJSON += json
                                case .thinkingDelta:
                                    // Extended thinking content — model reasoning internally.
                                    // Currently consumed silently; could surface as a "thinking" UI indicator.
                                    break
                                case .signatureDelta:
                                    // Response signature for verification — consumed silently.
                                    break
                                }

                            case .contentBlockStop:
                                if let toolId = currentToolId, let toolName = currentToolName {
                                    let inputData = currentToolInputJSON.data(using: .utf8) ?? Data()
                                    let input = (try? JSONDecoder().decode(
                                        [String: AnyCodable].self, from: inputData
                                    )) ?? [:]
                                    toolUseBlocks.append(ContentBlock.ToolUseBlock(
                                        id: toolId, name: toolName, input: input
                                    ))
                                    currentToolId = nil
                                    currentToolName = nil
                                    currentToolInputJSON = ""
                                }

                            case .messageDelta(let payload):
                                stopReason = payload.delta.stopReason
                                if let usage = payload.usage {
                                    cumulativeUsage.outputTokens += usage.outputTokens
                                }

                            case .messageStop, .ping:
                                break

                            case .error(let apiError):
                                wtLog("[AnthropicAPIProvider] API error: \(apiError.errorMessage)")
                                continuation.yield(.error(apiError.errorMessage))
                            }
                        }

                        // Build assistant content blocks
                        var assistantBlocks: [ContentBlock] = []
                        if !textAccumulator.isEmpty {
                            assistantBlocks.append(.text(textAccumulator))
                        }
                        for tu in toolUseBlocks {
                            assistantBlocks.append(.toolUse(tu))
                        }
                        state.addAssistantResponse(assistantBlocks)

                        // Handle stop reason
                        if stopReason == "tool_use" && !toolUseBlocks.isEmpty {
                            // Auto-checkpoint
                            let writeOps = toolUseBlocks.filter {
                                $0.name == "write_file" || $0.name == "edit_file"
                            }
                            if writeOps.count >= 2 {
                                let _ = await executor.execute(
                                    name: "checkpoint_create",
                                    input: ["name": AnyCodable("auto: before \(writeOps.count)-file edit")]
                                )
                            }

                            // Execute tools
                            var toolResults: [(toolUseId: String, content: String, isError: Bool)] = []
                            for tu in toolUseBlocks {
                                if self.isCancelled { break }

                                let inputJSON = (try? String(
                                    data: JSONEncoder().encode(tu.input),
                                    encoding: .utf8
                                )) ?? "{}"
                                continuation.yield(.toolStart(name: tu.name, input: inputJSON))

                                let result = await executor.execute(name: tu.name, input: tu.input)
                                toolResults.append((tu.id, result.content, result.isError))
                                continuation.yield(.toolEnd(
                                    name: tu.name,
                                    result: String(result.content.prefix(200)),
                                    isError: result.isError
                                ))
                            }

                            state.addToolResults(toolResults)
                            textAccumulator = ""
                            toolUseBlocks = []
                        } else {
                            break
                        }
                    }

                    state.recordUsage(cumulativeUsage)
                    try? state.persist()
                    let finalUsage = state.tokenUsage
                    WakeLock.shared.release()
                    continuation.yield(.done(usage: finalUsage))
                    continuation.finish()
                } catch {
                    wtLog("[AnthropicAPIProvider] ERROR: \(error)")
                    WakeLock.shared.release()
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }

                self.currentTask = nil
                self.isRunning = false
            }

            continuation.onTermination = { [weak self] _ in
                // onTermination can fire on any thread; cancel() touches @MainActor state
                Task { @MainActor [weak self] in self?.cancel() }
            }
        }
    }

    // MARK: - Cancel

    func cancel() {
        // Schedule on MainActor to avoid data race on isCancelled/isRunning/currentTask
        Task { @MainActor [weak self] in
            self?.isCancelled = true
            self?.currentTask?.cancel()
            self?.currentTask = nil
            self?.isRunning = false
            WakeLock.shared.release()
        }
    }

    // MARK: - State Manager

    @MainActor
    private func getOrCreateStateManager(context: ProviderSendContext) async throws -> ConversationStateManager {
        if let existing = stateManager, existing.sessionId == context.sessionId {
            return existing
        }

        if let restored = try ConversationStateManager.restore(
            sessionId: context.sessionId, branchId: context.branchId
        ) {
            stateManager = restored
            return restored
        }

        // Try parent branch inheritance
        if let parentSessionId = context.parentSessionId {
            if let parentState = try ConversationStateManager.restore(
                sessionId: parentSessionId, branchId: context.branchId
            ) {
                let forked = ConversationStateManager.fork(
                    from: parentState,
                    upToMessageIndex: parentState.apiMessages.count,
                    newSessionId: context.sessionId,
                    newBranchId: context.branchId
                )
                stateManager = forked
                return forked
            }
        }

        // Rebuild from stored messages
        let messages = try MessageStore.shared.getMessages(sessionId: context.sessionId)
        if !messages.isEmpty {
            let manager = ConversationStateManager(sessionId: context.sessionId, branchId: context.branchId)
            await manager.buildFromMessages(messages, project: context.project, workingDirectory: context.workingDirectory)
            stateManager = manager
            return manager
        }

        // Fresh session
        let manager = ConversationStateManager(sessionId: context.sessionId, branchId: context.branchId)
        _ = await manager.buildSystemPrompt(project: context.project, workingDirectory: context.workingDirectory)
        stateManager = manager
        return manager
    }

    // MARK: - Context Warm-Up

    /// Pre-build and cache the ConversationStateManager for a session before the first message.
    /// Called when a conversation is opened — eliminates cold-start delay on first send.
    func warmUp(sessionId: String, branchId: String, project: String?, workingDirectory: String?) async {
        // Already warm for this session
        if let existing = stateManager, existing.sessionId == sessionId { return }

        wtLog("[AnthropicAPIProvider] warming context for session=\(sessionId)")

        let context = ProviderSendContext(
            message: "",
            sessionId: sessionId,
            branchId: branchId,
            workingDirectory: workingDirectory,
            project: project
        )

        _ = try? await getOrCreateStateManager(context: context)
        wtLog("[AnthropicAPIProvider] context warm for session=\(sessionId)")
    }

    // MARK: - Helpers

    private func queryKnowledgeBase(message: String) async -> String {
        let kbCli = "\(home)/.cortana/bin/cortana-kb"
        guard FileManager.default.fileExists(atPath: kbCli) else { return "" }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.bunExecutable)
        proc.arguments = [kbCli, "search", message]
        proc.currentDirectoryURL = URL(fileURLWithPath: "\(home)/Development/cortana-core")

        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "/opt/homebrew/bin:\(home)/.local/bin:\(existingPath)"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()

            // Wait with a 5-second timeout — bun can hang if DB is locked
            let result: String? = await withCheckedContinuation { continuation in
                let resumeGuard = OneShotGuard()

                @Sendable func safeResume(_ value: String?) {
                    guard resumeGuard.tryFire() else { return }
                    continuation.resume(returning: value)
                }

                let timeoutWork = DispatchWorkItem { [weak proc] in
                    if let proc, proc.isRunning {
                        wtLog("[AnthropicAPIProvider] KB query timed out after 5s — terminating")
                        proc.terminate()
                    }
                    safeResume(nil)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5), execute: timeoutWork)

                proc.terminationHandler = { _ in
                    timeoutWork.cancel()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    safeResume(output)
                }
            }

            guard let result, !result.isEmpty else { return "" }
            return String(result.prefix(2000))
        } catch {
            return ""
        }
    }
}
