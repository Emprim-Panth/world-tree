import Foundation

// MARK: - Summary Styles

/// What kind of summary to generate — affects the prompt and expected output.
enum SummaryStyle {
    case branchComplete   // Full summary for completed branches
    case checkpoint       // Working-state summary for session rotation
    case digest           // Compact summary for parent absorption
}

// MARK: - Branch Summarizer

/// Generates intelligent summaries using Claude CLI (Haiku for speed).
///
/// Used for:
/// - Branch completion summaries (replace 200-char truncation)
/// - Session rotation checkpoints (capture working state before rotating)
/// - Digest absorption (compact child results for parent injection)
@MainActor
final class BranchSummarizer {
    static let shared = BranchSummarizer()

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private init() {}

    // MARK: - Public API

    /// Generate a summary of a branch's conversation.
    func summarize(sessionId: String, style: SummaryStyle = .branchComplete) async -> String? {
        let messages = (try? MessageStore.shared.getMessages(sessionId: sessionId)) ?? []
        guard !messages.isEmpty else { return nil }

        let conversationText = formatMessages(messages, maxChars: 15_000)
        let prompt = buildPrompt(for: style, conversation: conversationText)

        return await runSummarization(prompt: prompt)
    }

    /// Generate a checkpoint summary for session rotation.
    /// Focuses on recent messages and working state.
    func checkpoint(sessionId: String, recentMessageCount: Int = 20) async -> String? {
        let allMessages = (try? MessageStore.shared.getMessages(sessionId: sessionId)) ?? []
        guard !allMessages.isEmpty else { return nil }

        // Take the last N messages for checkpoint focus
        let recentMessages = Array(allMessages.suffix(recentMessageCount))
        let conversationText = formatMessages(recentMessages, maxChars: 10_000)

        // Also include a brief summary of earlier context if there's more
        var earlierContext = ""
        if allMessages.count > recentMessageCount {
            let earlierMessages = Array(allMessages.prefix(allMessages.count - recentMessageCount))
            let earlierChars = earlierMessages.reduce(0) { $0 + $1.content.count }
            earlierContext = "[Earlier: \(earlierMessages.count) messages, ~\(earlierChars / 4) tokens of prior context]\n\n"
        }

        let prompt = buildPrompt(for: .checkpoint, conversation: earlierContext + conversationText)
        return await runSummarization(prompt: prompt)
    }

    // MARK: - Formatting

    /// Format messages into a readable transcript for the summarizer.
    private func formatMessages(_ messages: [Message], maxChars: Int) -> String {
        var result = ""
        var remaining = maxChars

        for message in messages {
            let role = message.role == .user ? "User" : message.role == .assistant ? "Assistant" : "System"
            let content: String
            if message.content.count > remaining {
                content = String(message.content.prefix(remaining)) + "..."
                remaining = 0
            } else {
                content = message.content
                remaining -= message.content.count
            }

            result += "[\(role)]: \(content)\n\n"

            if remaining <= 0 { break }
        }

        return result
    }

    // MARK: - Prompts

    private func buildPrompt(for style: SummaryStyle, conversation: String) -> String {
        switch style {
        case .branchComplete:
            return """
                Summarize this conversation branch concisely. Capture:
                1. What was accomplished (key outcomes and decisions)
                2. What was discussed but not resolved
                3. Any code changes or files modified
                4. Key technical decisions and their rationale

                Keep it under 500 words. Use bullet points. Be specific about files and functions.

                Conversation:
                \(conversation)
                """

        case .checkpoint:
            return """
                Create a working-state checkpoint of this conversation. This will be used to continue the conversation in a fresh context window. Capture:
                1. Current task and what we're working on RIGHT NOW
                2. Key decisions already made (don't re-discuss)
                3. Files being modified and their current state
                4. Any open questions or next steps
                5. Important context that must not be lost

                Be comprehensive but compact. Under 800 words. The new session needs enough context to continue seamlessly.

                Conversation:
                \(conversation)
                """

        case .digest:
            return """
                Create a compact digest of this branch's work for injection into a parent conversation. Include:
                1. What was accomplished (2-3 sentences)
                2. Key results or findings
                3. Files changed (if any)

                Keep it under 200 words. Dense, information-rich, no filler.

                Conversation:
                \(conversation)
                """
        }
    }

    // MARK: - CLI Execution

    /// Run the summarization via Claude CLI with max-turns 1.
    private func runSummarization(prompt: String) async -> String? {
        let cliPath = "\(home)/.local/bin/claude"
        guard FileManager.default.fileExists(atPath: cliPath) else {
            canvasLog("[BranchSummarizer] Claude CLI not found")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cliPath)
            proc.arguments = [
                "-p", prompt,
                "--output-format", "text",
                "--max-turns", "1",
                "--model", "claude-haiku-4-5-20251001",
                "--dangerously-skip-permissions",
            ]

            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(home)/.local/bin:\(home)/.cortana/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
            env["HOME"] = home
            proc.environment = env

            let stdoutPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = FileHandle.nullDevice

            proc.terminationHandler = { process in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if process.terminationStatus == 0, let output, !output.isEmpty {
                    continuation.resume(returning: output)
                } else {
                    canvasLog("[BranchSummarizer] CLI exited with status \(process.terminationStatus)")
                    continuation.resume(returning: nil)
                }
            }

            do {
                try proc.run()
            } catch {
                canvasLog("[BranchSummarizer] Failed to launch CLI: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }
}
