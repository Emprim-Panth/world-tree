import Foundation

/// Events yielded during a conversation turn — text streaming, tool activity, completion.
enum BridgeEvent {
    case text(String)
    case toolStart(name: String, input: String)
    case toolEnd(name: String, result: String, isError: Bool)
    case done(usage: SessionTokenUsage)
    case error(String)
}

/// Orchestrates Claude communication via direct Anthropic API with local tool execution.
/// Falls back to CLI spawning when no API key is available.
final class ClaudeBridge {
    private var currentTask: Task<Void, Never>?
    private var stateManager: ConversationStateManager?
    private let apiClient: AnthropicClient?
    private var isCancelled = false

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let maxToolLoopIterations = 25

    init() {
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] {
            self.apiClient = AnthropicClient(apiKey: key)
        } else {
            self.apiClient = nil
        }
    }

    var isRunning: Bool { currentTask != nil && !isCancelled }
    var hasAPIAccess: Bool { apiClient != nil }

    // MARK: - Primary Send (API)

    func send(
        message: String,
        sessionId: String,
        branchId: String,
        model: String?,
        workingDirectory: String?,
        project: String?
    ) -> AsyncStream<BridgeEvent> {
        guard let apiClient else {
            // Fallback to CLI
            return sendViaCLI(
                message: message,
                sessionId: sessionId,
                model: model,
                workingDirectory: workingDirectory,
                project: project
            )
        }

        isCancelled = false

        return AsyncStream { continuation in
            currentTask = Task { @MainActor in
                do {
                    // Get or restore state manager
                    let state = try getOrCreateStateManager(
                        sessionId: sessionId,
                        branchId: branchId,
                        project: project,
                        workingDirectory: workingDirectory
                    )

                    // Query KB for this message
                    let kbContext = queryKnowledgeBase(message: message)
                    state.appendKBContext(kbContext)

                    // Add user message
                    state.addUserMessage(message)

                    let selectedModel = model ?? CortanaConstants.defaultModel
                    let cwd = resolveWorkingDirectory(workingDirectory, project: project)
                    let executor = ToolExecutor(workingDirectory: URL(fileURLWithPath: cwd))
                    var cumulativeUsage = TokenUsage.zero

                    // Tool loop
                    for _ in 0..<maxToolLoopIterations {
                        if isCancelled { break }

                        let request = AnthropicRequest(
                            model: selectedModel,
                            maxTokens: 8192,
                            system: state.systemBlocks,
                            tools: CanvasTools.definitions(),
                            messages: state.messagesForAPI(),
                            stream: true
                        )

                        // Stream the API call
                        var textAccumulator = ""
                        var toolUseBlocks: [ContentBlock.ToolUseBlock] = []
                        var currentToolId: String?
                        var currentToolName: String?
                        var currentToolInputJSON = ""
                        var stopReason: String?

                        let stream = apiClient.stream(request: request)

                        for try await event in stream {
                            if isCancelled { break }

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
                                // If we were accumulating a tool_use, finalize it
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

                            case .messageStop, .ping, .error:
                                break
                            }
                        }

                        // Build assistant content blocks for state
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
                            // Execute tools
                            var toolResults: [(toolUseId: String, content: String, isError: Bool)] = []

                            for tu in toolUseBlocks {
                                if isCancelled { break }

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

                            // Reset for next loop iteration
                            textAccumulator = ""
                            toolUseBlocks = []
                        } else {
                            // end_turn or max_tokens — done
                            break
                        }
                    }

                    // Record usage and persist state
                    state.recordUsage(cumulativeUsage)
                    try? state.persist()

                    continuation.yield(.done(usage: state.tokenUsage))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }

                currentTask = nil
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
        // Also cancel any legacy CLI process
        legacyProcess?.terminate()
        legacyProcess = nil
    }

    // MARK: - State Manager

    @MainActor
    private func getOrCreateStateManager(
        sessionId: String,
        branchId: String,
        project: String?,
        workingDirectory: String?
    ) throws -> ConversationStateManager {
        // Reuse existing if same session
        if let existing = stateManager, existing.sessionId == sessionId {
            return existing
        }

        // Try to restore from database
        if let restored = try ConversationStateManager.restore(sessionId: sessionId, branchId: branchId) {
            stateManager = restored
            return restored
        }

        // Create fresh
        let manager = ConversationStateManager(sessionId: sessionId, branchId: branchId)
        _ = manager.buildSystemPrompt(project: project, workingDirectory: workingDirectory)
        stateManager = manager
        return manager
    }

    // MARK: - Working Directory Resolution

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

    // MARK: - Knowledge Base Query

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

    // MARK: - CLI Fallback

    private var legacyProcess: Process?

    /// Fallback: spawn claude CLI when no API key is available.
    private func sendViaCLI(
        message: String,
        sessionId: String,
        model: String?,
        workingDirectory: String?,
        project: String?
    ) -> AsyncStream<BridgeEvent> {
        AsyncStream { continuation in
            let selectedModel = model ?? CortanaConstants.defaultModel
            let cwd = resolveWorkingDirectory(workingDirectory, project: project)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "\(home)/.local/bin/claude")
            proc.arguments = [
                "--dangerously-skip-permissions",
                "--model", selectedModel,
                "-p", message,
            ]
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

            var env = ProcessInfo.processInfo.environment
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(home)/.local/bin:\(home)/.cortana/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
            env["HOME"] = home
            proc.environment = env

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice

            self.legacyProcess = proc

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    continuation.finish()
                    return
                }
                if let text = String(data: data, encoding: .utf8) {
                    continuation.yield(.text(text))
                }
            }

            proc.terminationHandler = { [weak self] _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.yield(.done(usage: .init()))
                continuation.finish()
                self?.legacyProcess = nil
            }

            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }

            do {
                try proc.run()
            } catch {
                continuation.yield(.error(error.localizedDescription))
                continuation.finish()
            }
        }
    }
}
