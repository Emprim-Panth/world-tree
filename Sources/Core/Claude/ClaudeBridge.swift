import Foundation

/// Spawns claude CLI and streams responses back.
/// Uses `-p` with conversation context for each message.
final class ClaudeBridge {
    private var process: Process?
    private var outputPipe: Pipe?

    /// The claude CLI binary path
    private let claudePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin/claude"
    }()

    deinit {
        cancel()
    }

    /// Send a message with conversation context, streaming the response line by line.
    func send(
        message: String,
        conversationHistory: [Message],
        model: String? = nil,
        workingDirectory: String? = nil
    ) -> AsyncStream<String> {
        AsyncStream { continuation in
            let prompt = buildPrompt(message: message, history: conversationHistory)
            let selectedModel = model ?? CortanaConstants.defaultModel

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: claudePath)
            proc.arguments = [
                "--dangerously-skip-permissions",
                "--model", selectedModel,
                "-p", prompt
            ]

            if let cwd = workingDirectory {
                proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }

            // Inherit PATH so claude can find its dependencies
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:\(existingPath)"
            proc.environment = env

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice

            self.process = proc
            self.outputPipe = pipe

            // Read stdout on a background thread
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    // EOF — process finished
                    continuation.finish()
                    return
                }
                if let text = String(data: data, encoding: .utf8) {
                    continuation.yield(text)
                }
            }

            proc.terminationHandler = { [weak self] _ in
                // Ensure we clean up
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

    // MARK: - Prompt Building

    /// Build a prompt with conversation history for context
    private func buildPrompt(message: String, history: [Message]) -> String {
        // Filter to user/assistant messages, skip system
        let relevant = history.filter { $0.role != .system }

        // If no history, just send the message
        guard !relevant.isEmpty else { return message }

        // Take last N exchanges for context (avoid token bloat)
        let contextMessages = relevant.suffix(20)

        var parts: [String] = []

        if contextMessages.count > 1 {
            parts.append("[Continuing conversation]")
            for msg in contextMessages.dropLast() {
                let role = msg.role == .user ? "User" : "Cortana"
                // Truncate long messages in history to save tokens
                let content = msg.content.count > 1000
                    ? String(msg.content.prefix(1000)) + "..."
                    : msg.content
                parts.append("\(role): \(content)")
            }
            parts.append("")
        }

        // The actual current message (last one if it's the user message we just sent)
        if let last = contextMessages.last, last.role == .user {
            parts.append(last.content)
        } else {
            parts.append(message)
        }

        return parts.joined(separator: "\n")
    }
}
