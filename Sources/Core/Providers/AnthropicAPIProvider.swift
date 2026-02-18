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

    private(set) var isRunning = false

    private let apiClient: AnthropicClient
    private var stateManager: ConversationStateManager?
    private var currentTask: Task<Void, Never>?
    private var isCancelled = false

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let maxToolLoopIterations = 25

    init(apiKey: String) {
        self.apiClient = AnthropicClient(apiKey: apiKey)
    }

    // MARK: - Health Check

    func checkHealth() async -> ProviderHealth {
        // A simple HEAD or tiny request would be ideal,
        // but just check that the key looks valid
        return .available
    }

    // MARK: - Send

    func send(context: ProviderSendContext) -> AsyncStream<BridgeEvent> {
        isCancelled = false
        isRunning = true

        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.yield(.error("Provider deallocated"))
                continuation.finish()
                return
            }

            self.currentTask = Task { @MainActor [weak self] in
                guard let self else { return }

                do {
                    canvasLog("[AnthropicAPIProvider] send() started for session=\(context.sessionId)")

                    let state = try await self.getOrCreateStateManager(context: context)
                    canvasLog("[AnthropicAPIProvider] state manager ready, system blocks=\(state.systemBlocks.count)")

                    // Refresh terminal context (captures latest PTY output before each message)
                    state.refreshTerminalContext()

                    // Query KB
                    let kbContext = self.queryKnowledgeBase(message: context.message)
                    state.appendKBContext(kbContext)

                    // Add user message (with any image/file attachments)
                    state.addUserMessage(context.message, attachments: context.attachments)

                    let selectedModel = context.model ?? CortanaConstants.defaultModel
                    let cwd = self.resolveWorkingDirectory(context.workingDirectory, project: context.project)
                    let executor = ToolExecutor(workingDirectory: URL(fileURLWithPath: cwd))
                    var cumulativeUsage = TokenUsage.zero

                    // Tool loop
                    for _ in 0..<self.maxToolLoopIterations {
                        if self.isCancelled { break }

                        let request = AnthropicRequest(
                            model: selectedModel,
                            maxTokens: 8192,
                            system: state.systemBlocks,
                            tools: CanvasTools.definitions(),
                            messages: state.messagesForAPI(),
                            stream: true
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
                                canvasLog("[AnthropicAPIProvider] API error: \(apiError.errorMessage)")
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
                    continuation.yield(.done(usage: state.tokenUsage))
                    continuation.finish()
                } catch {
                    canvasLog("[AnthropicAPIProvider] ERROR: \(error)")
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }

                self.currentTask = nil
                self.isRunning = false
            }

            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }
        }
    }

    // MARK: - Cancel

    func cancel() {
        isCancelled = true
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
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

        canvasLog("[AnthropicAPIProvider] warming context for session=\(sessionId)")

        let context = ProviderSendContext(
            message: "",
            sessionId: sessionId,
            branchId: branchId,
            workingDirectory: workingDirectory,
            project: project
        )

        _ = try? await getOrCreateStateManager(context: context)
        canvasLog("[AnthropicAPIProvider] context warm for session=\(sessionId)")
    }

    // MARK: - Helpers

    private func resolveWorkingDirectory(_ explicit: String?, project: String?) -> String {
        if let dir = explicit, FileManager.default.fileExists(atPath: dir) {
            return dir
        }
        if let project {
            let devRoot = "\(home)/Development"
            let candidates = [
                "\(devRoot)/\(project)",
                "\(devRoot)/\(project.lowercased())",
                "\(devRoot)/\(project.replacingOccurrences(of: " ", with: "-"))",
            ]
            for path in candidates {
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return "\(home)/Development"
    }

    private func queryKnowledgeBase(message: String) -> String {
        let kbCli = "\(home)/.cortana/bin/cortana-kb"
        guard FileManager.default.fileExists(atPath: kbCli) else { return "" }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/bun")
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
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8),
                  !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ""
            }
            return String(output.prefix(2000))
        } catch {
            return ""
        }
    }
}
