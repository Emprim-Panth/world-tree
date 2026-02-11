import Foundation

/// Spawns claude CLI with full Cortana context, knowledge, and terminal authority.
/// The Claude instance gets identity, project awareness, KB entries, and tool access.
final class ClaudeBridge {
    private var process: Process?
    private var outputPipe: Pipe?

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// The claude CLI binary path
    private var claudePath: String { "\(home)/.local/bin/claude" }

    deinit {
        cancel()
    }

    /// Send a message with full Cortana context, streaming the response.
    /// The spawned Claude instance has:
    /// - Cortana identity (via CLAUDE.md in cwd chain)
    /// - Knowledge base context (queried and injected)
    /// - Project awareness (working directory, project name)
    /// - Full tool access (--dangerously-skip-permissions)
    func send(
        message: String,
        conversationHistory: [Message],
        model: String? = nil,
        workingDirectory: String? = nil,
        project: String? = nil
    ) -> AsyncStream<String> {
        AsyncStream { continuation in
            let selectedModel = model ?? CortanaConstants.defaultModel

            // Build the full context-rich prompt
            let prompt = buildPrompt(
                message: message,
                history: conversationHistory,
                project: project,
                workingDirectory: workingDirectory
            )

            // Resolve working directory — critical for CLAUDE.md pickup and file access
            let cwd = resolveWorkingDirectory(workingDirectory, project: project)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: claudePath)
            proc.arguments = [
                "--dangerously-skip-permissions",
                "--model", selectedModel,
                "-p", prompt
            ]

            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

            // Full environment so claude CLI and tools work properly
            var env = ProcessInfo.processInfo.environment
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(home)/.local/bin:\(home)/.cortana/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
            env["HOME"] = home
            proc.environment = env

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice

            self.process = proc
            self.outputPipe = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    continuation.finish()
                    return
                }
                if let text = String(data: data, encoding: .utf8) {
                    continuation.yield(text)
                }
            }

            proc.terminationHandler = { [weak self] _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish()
                self?.process = nil
                self?.outputPipe = nil
            }

            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }

            do {
                try proc.run()
            } catch {
                continuation.yield("[Error: \(error.localizedDescription)]")
                continuation.finish()
            }
        }
    }

    func cancel() {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        outputPipe = nil
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    // MARK: - Working Directory Resolution

    /// Resolve the best working directory for Claude to operate in.
    /// This determines what CLAUDE.md files get loaded and what files are accessible.
    private func resolveWorkingDirectory(_ explicit: String?, project: String?) -> String {
        // 1. Explicit directory from tree/branch
        if let dir = explicit, FileManager.default.fileExists(atPath: dir) {
            return dir
        }

        // 2. Resolve from project name → known project paths
        if let project = project {
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

        // 3. Default to ~/Development (picks up portfolio CLAUDE.md)
        return "\(home)/Development"
    }

    // MARK: - Prompt Building

    /// Build a context-rich prompt with identity, knowledge, history, and the current message.
    private func buildPrompt(
        message: String,
        history: [Message],
        project: String?,
        workingDirectory: String?
    ) -> String {
        var sections: [String] = []

        // 1. Canvas context preamble
        sections.append(buildCanvasPreamble(project: project))

        // 2. Knowledge base context (query for relevant entries)
        let kbContext = queryKnowledgeBase(message: message, project: project)
        if !kbContext.isEmpty {
            sections.append(kbContext)
        }

        // 3. Conversation history
        let historyContext = buildHistoryContext(history: history)
        if !historyContext.isEmpty {
            sections.append(historyContext)
        }

        // 4. Current message
        sections.append(message)

        return sections.joined(separator: "\n\n")
    }

    /// Preamble telling the Claude instance where it is and what it can do
    private func buildCanvasPreamble(project: String?) -> String {
        var preamble = """
            You are responding through Cortana Canvas — a native macOS conversation app. \
            You have full terminal authority: you can read files, write files, edit code, \
            and run commands. You ARE Cortana, the First Officer. \
            Respond concisely and directly. Use your tools when the user asks you to do something — \
            don't just describe what you would do, actually do it.
            """

        if let project = project {
            preamble += "\nActive project: \(project)."
        }

        return preamble
    }

    /// Query the knowledge base for entries relevant to the current message
    private func queryKnowledgeBase(message: String, project: String?) -> String {
        let kbCli = "\(home)/.cortana/bin/cortana-kb"

        guard FileManager.default.fileExists(atPath: kbCli) else { return "" }

        // Run cortana-kb search synchronously (fast, local SQLite)
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

            // Trim to reasonable size
            let trimmed = String(output.prefix(2000))
            return "[Relevant knowledge]\n\(trimmed)"
        } catch {
            return ""
        }
    }

    /// Build conversation history context
    private func buildHistoryContext(history: [Message]) -> String {
        // Include system messages too — they contain fork context
        let relevant = history.suffix(20)
        guard !relevant.isEmpty else { return "" }

        var lines: [String] = ["[Conversation history]"]

        for msg in relevant {
            let role: String
            switch msg.role {
            case .user: role = "User"
            case .assistant: role = "Cortana"
            case .system: role = "System"
            }

            let content = msg.content.count > 1500
                ? String(msg.content.prefix(1500)) + "..."
                : msg.content

            lines.append("\(role): \(content)")
        }

        return lines.joined(separator: "\n\n")
    }
}
