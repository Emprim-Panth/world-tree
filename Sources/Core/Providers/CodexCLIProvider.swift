import Foundation

/// Direct provider backed by the local Codex CLI using OpenAI credentials.
/// Mirrors the one-shot execution model already used by Starfleet's Codex runtime.
final class CodexCLIProvider: LLMProvider {
    let displayName = "Codex CLI (OpenAI)"
    let identifier = "codex-cli"
    let capabilities: ProviderCapabilities = [.streaming, .toolExecution, .modelSelection]

    private let stateLock = NSLock()
    private var _isRunning = false
    private var _currentProcess: Process?
    private var _activeProcesses: [ObjectIdentifier: Process] = [:]
    private var _activeProcessOrder: [ObjectIdentifier] = []

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

    private let parseQueue = DispatchQueue(label: "com.cortana.canvas.codex-parser")
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private static let executablePath: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
        ]

        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }()

    private struct CodexEventEnvelope: Decodable {
        let type: String
        let threadId: String?
        let message: String?
        let item: CodexItem?
        let usage: CodexUsage?
        let error: CodexError?

        enum CodingKeys: String, CodingKey {
            case type
            case threadId = "thread_id"
            case message
            case item
            case usage
            case error
        }
    }

    private struct CodexItem: Decodable {
        let id: String?
        let type: String
        let text: String?
        let message: String?
        let command: String?
        let aggregatedOutput: String?
        let exitCode: Int?
        let status: String?

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case text
            case message
            case command
            case aggregatedOutput = "aggregated_output"
            case exitCode = "exit_code"
            case status
        }
    }

    private struct CodexUsage: Decodable {
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    private struct CodexError: Decodable {
        let message: String?
    }

    static func isInstalled() -> Bool {
        executablePath != nil
    }

    func checkHealth() async -> ProviderHealth {
        guard let executable = Self.executablePath else {
            return .unavailable(reason: "Codex CLI not found")
        }

        if OpenAIKeyStore.resolveAPIKey() != nil || Self.hasStoredLoginSync(executablePath: executable) {
            return .available
        }

        return .unavailable(reason: "OpenAI API key not configured")
    }

    func send(context: ProviderSendContext) -> AsyncStream<BridgeEvent> {
        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.yield(.error("Provider deallocated"))
                continuation.finish()
                return
            }

            guard let executable = Self.executablePath else {
                continuation.yield(.error("Codex CLI not found"))
                continuation.finish()
                return
            }

            let apiKey = OpenAIKeyStore.resolveAPIKey()
            let hasStoredLogin = Self.hasStoredLoginSync(executablePath: executable)
            guard apiKey != nil || hasStoredLogin else {
                continuation.yield(.error("OpenAI API key not configured"))
                continuation.finish()
                return
            }

            let attachmentPrep = self.prepareAttachments(context.attachments)
            let prompt = self.buildPrompt(context: context, textAttachmentBlock: attachmentPrep.textBlock)
            let cwd = resolveWorkingDirectory(context.workingDirectory, project: context.project)
            Task { @MainActor in
                _ = BranchTerminalManager.shared.preparePreferredSession(
                    branchId: context.branchId,
                    project: context.project,
                    workingDirectory: cwd
                )
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)

            var args = ["exec", "--json", "--full-auto", "-C", cwd]
            if Self.shouldSkipGitRepoCheck(for: cwd) {
                args.append("--skip-git-repo-check")
            }
            if let modelArg = Self.modelArgument(for: context.model) {
                args += ["-m", modelArg]
            }
            for imagePath in attachmentPrep.imagePaths {
                args += ["-i", imagePath]
            }
            args.append(prompt)
            proc.arguments = args
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

            var env = ProcessInfo.processInfo.environment
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(home)/.local/bin:\(home)/.cortana/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
            env["HOME"] = home
            if let apiKey {
                env["OPENAI_API_KEY"] = apiKey
            }
            proc.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            WakeLock.shared.acquire()
            registerActiveProcess(proc)

            var usage = SessionTokenUsage()
            var stderrData = Data()
            var bufferedStdout = Data()
            var emittedError = false
            let decoder = JSONDecoder()

            func cleanup() {
                attachmentPrep.cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }

                self?.parseQueue.async {
                    bufferedStdout.append(data)

                    while let newlineRange = bufferedStdout.firstRange(of: Data([0x0A])) {
                        let lineData = bufferedStdout.subdata(in: 0..<newlineRange.lowerBound)
                        bufferedStdout.removeSubrange(0...newlineRange.lowerBound)
                        guard let line = String(data: lineData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                              !line.isEmpty
                        else {
                            continue
                        }

                        self?.handleCodexLine(
                            line,
                            decoder: decoder,
                            continuation: continuation,
                            usage: &usage,
                            emittedError: &emittedError
                        )
                    }
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self.parseQueue.async {
                    stderrData.append(data)
                }
            }

            proc.terminationHandler = { [weak self] process in
                self?.parseQueue.async {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    if !bufferedStdout.isEmpty,
                       let line = String(data: bufferedStdout, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !line.isEmpty {
                        self?.handleCodexLine(
                            line,
                            decoder: decoder,
                            continuation: continuation,
                            usage: &usage,
                            emittedError: &emittedError
                        )
                    }

                    self?.unregisterActiveProcess(proc)

                    WakeLock.shared.release()
                    cleanup()

                    if process.terminationStatus == 0 && !emittedError {
                        continuation.yield(.done(usage: usage))
                    } else if !emittedError {
                        let stderrText = String(data: stderrData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let message = stderrText.isEmpty
                            ? "Codex exited with status \(process.terminationStatus)"
                            : stderrText
                        continuation.yield(.error(message))
                    }

                    continuation.finish()
                }
            }

            do {
                try proc.run()
            } catch {
                unregisterActiveProcess(proc)
                WakeLock.shared.release()
                cleanup()
                continuation.yield(.error(error.localizedDescription))
                continuation.finish()
            }

            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                self?.unregisterActiveProcess(proc)
                proc.terminate()
                WakeLock.shared.release()
            }
        }
    }

    func cancel() {
        stateLock.lock()
        let process = _currentProcess
        if let process {
            let id = ObjectIdentifier(process)
            _activeProcesses.removeValue(forKey: id)
            _activeProcessOrder.removeAll { $0 == id }
            _currentProcess = _activeProcessOrder.last.flatMap { _activeProcesses[$0] }
            _isRunning = !_activeProcesses.isEmpty
        } else {
            _isRunning = !_activeProcesses.isEmpty
        }
        stateLock.unlock()

        process?.terminate()
        WakeLock.shared.release()
    }

    func registerActiveProcess(_ process: Process) {
        stateLock.lock()
        defer { stateLock.unlock() }

        let id = ObjectIdentifier(process)
        _activeProcesses[id] = process
        _activeProcessOrder.removeAll { $0 == id }
        _activeProcessOrder.append(id)
        _currentProcess = process
        _isRunning = true
    }

    func unregisterActiveProcess(_ process: Process) {
        stateLock.lock()
        defer { stateLock.unlock() }

        let id = ObjectIdentifier(process)
        _activeProcesses.removeValue(forKey: id)
        _activeProcessOrder.removeAll { $0 == id }

        if _currentProcess === process {
            _currentProcess = _activeProcessOrder.last.flatMap { _activeProcesses[$0] }
        }

        _isRunning = !_activeProcesses.isEmpty
    }

    var activeProcessCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _activeProcessOrder.count
    }

    func isCurrentProcess(_ process: Process) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentProcess === process
    }

    private func handleCodexLine(
        _ line: String,
        decoder: JSONDecoder,
        continuation: AsyncStream<BridgeEvent>.Continuation,
        usage: inout SessionTokenUsage,
        emittedError: inout Bool
    ) {
        guard let data = line.data(using: .utf8),
              let event = try? decoder.decode(CodexEventEnvelope.self, from: data)
        else {
            return
        }

        switch event.type {
        case "item.started":
            guard let item = event.item,
                  item.type == "command_execution"
            else { return }

            let command = item.command ?? ""
            let inputJSON = #"{"command":"\#(escapeJSONString(command))"}"#
            continuation.yield(.toolStart(name: "bash", input: inputJSON))

        case "item.completed":
            guard let item = event.item else { return }

            switch item.type {
            case "agent_message":
                if let text = item.text, !text.isEmpty {
                    continuation.yield(.text(text))
                }
            case "command_execution":
                continuation.yield(.toolEnd(
                    name: "bash",
                    result: item.aggregatedOutput ?? "",
                    isError: (item.exitCode ?? 0) != 0
                ))
            case "reasoning":
                if let text = item.text, !text.isEmpty {
                    continuation.yield(.thinking(text))
                }
            default:
                break
            }

        case "turn.completed":
            if let eventUsage = event.usage {
                usage.totalInputTokens += eventUsage.inputTokens ?? 0
                usage.cacheHitTokens += eventUsage.cachedInputTokens ?? 0
                usage.totalOutputTokens += eventUsage.outputTokens ?? 0
                usage.turnCount += 1
            }

        case "error", "turn.failed":
            let message = event.error?.message ?? event.message ?? "Codex request failed"
            emittedError = true
            continuation.yield(.error(message))

        default:
            break
        }
    }

    private func buildPrompt(context: ProviderSendContext, textAttachmentBlock: String) -> String {
        var parts: [String] = [
            "# Identity",
            context.systemPromptOverride
                ?? CortanaIdentity.cliSystemPrompt(
                    project: context.project,
                    workingDirectory: context.workingDirectory,
                    sessionId: context.sessionId
                ),
        ]

        if let recentContext = context.recentContext, !recentContext.isEmpty {
            parts += ["# Context", recentContext]
        }

        if !textAttachmentBlock.isEmpty {
            parts += ["# Attachments", textAttachmentBlock]
        }

        parts += ["# User Message", context.message]

        return parts.joined(separator: "\n\n")
    }

    private func prepareAttachments(_ attachments: [Attachment]) -> (imagePaths: [String], textBlock: String, cleanupURLs: [URL]) {
        guard !attachments.isEmpty else {
            return ([], "", [])
        }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worldtree-codex-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var imagePaths: [String] = []
        var textBlocks: [String] = []
        var cleanupURLs: [URL] = []

        for attachment in attachments {
            switch attachment.type {
            case .image:
                let fileURL = tempDir.appendingPathComponent("\(attachment.id.uuidString)-\(attachment.filename)")
                do {
                    try attachment.data.write(to: fileURL)
                    imagePaths.append(fileURL.path)
                    cleanupURLs.append(fileURL)
                    textBlocks.append("Image attached: \(attachment.filename)")
                } catch {
                    textBlocks.append("Image attachment could not be staged: \(attachment.filename)")
                }

            case .file:
                let body: String
                if let decoded = String(data: attachment.data, encoding: .utf8), !decoded.isEmpty {
                    body = decoded
                } else {
                    body = "Binary file attached (\(attachment.mimeType), \(attachment.data.count) bytes)."
                }

                textBlocks.append("""
                    File: \(attachment.filename)
                    MIME: \(attachment.mimeType)
                    \(body)
                    """)
            }
        }

        return (imagePaths, textBlocks.joined(separator: "\n\n"), cleanupURLs)
    }

    private static func modelArgument(for model: String?) -> String? {
        guard let model, !model.isEmpty, model != "codex" else {
            return nil
        }
        return model
    }

    static func shouldSkipGitRepoCheck(for workingDirectory: String) -> Bool {
        !isInsideGitRepository(workingDirectory)
    }

    static func isInsideGitRepository(_ workingDirectory: String) -> Bool {
        var currentURL = URL(fileURLWithPath: workingDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: currentURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }

        while true {
            let gitMarker = currentURL.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: gitMarker) {
                return true
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                return false
            }
            currentURL = parentURL
        }
    }

    private static func hasStoredLoginSync(executablePath: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = ["login", "status"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(home)/.local/bin:\(home)/.cortana/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        env["HOME"] = home
        proc.environment = env

        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
