import Foundation

// MARK: - CLI Session Info

/// Data extracted from a Claude CLI session JSONL file.
struct CLISessionInfo {
    let sessionId: String
    let workingDirectory: String
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let messageCount: Int
    let toolUseCount: Int
    let lastActivity: Date?
}

// MARK: - CLI Session Reader

/// Reads Claude CLI session JSONL files from `~/.claude/projects/` to extract
/// real token usage data. Used to monitor context pressure for tmux sessions
/// running Claude Code.
///
/// Claude CLI stores sessions at:
/// `~/.claude/projects/-Users-evanprimeau-Development-{Project}/{sessionId}.jsonl`
///
/// Each line is a JSON object with `type`, `sessionId`, `cwd`, and for assistant
/// messages, `message.usage` containing `input_tokens`, `cache_read_input_tokens`, etc.
enum CLISessionReader {

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Find the most recently active Claude session for a given working directory.
    /// Matches by converting the directory path to Claude's project directory format.
    static func findActiveSession(workingDirectory: String) -> CLISessionInfo? {
        let projectDir = projectDirectory(for: workingDirectory)
        guard FileManager.default.fileExists(atPath: projectDir) else { return nil }

        // Find the most recently modified JSONL file
        guard let latestFile = findLatestSessionFile(in: projectDir) else { return nil }

        return parseSessionFile(latestFile, workingDirectory: workingDirectory)
    }

    /// Get all Claude sessions for a working directory, sorted by recency.
    static func allSessions(workingDirectory: String) -> [CLISessionInfo] {
        let projectDir = projectDirectory(for: workingDirectory)
        guard FileManager.default.fileExists(atPath: projectDir) else { return [] }

        return sessionFiles(in: projectDir).compactMap {
            parseSessionFile($0, workingDirectory: workingDirectory)
        }.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    // MARK: - Path Resolution

    /// Convert a working directory path to Claude's project directory format.
    /// Claude stores projects as: `~/.claude/projects/-Users-evanprimeau-Development-ProjectName/`
    private static func projectDirectory(for workingDirectory: String) -> String {
        // Claude replaces "/" with "-" and prepends "-" for the root "/"
        let encoded = workingDirectory.replacingOccurrences(of: "/", with: "-")
        return "\(home)/.claude/projects/\(encoded)"
    }

    /// Find the most recently modified JSONL file in a project directory.
    private static func findLatestSessionFile(in directory: String) -> String? {
        let files = sessionFiles(in: directory)
        return files.max { a, b in
            modificationDate(a) < modificationDate(b)
        }
    }

    /// All JSONL session files in a directory.
    private static func sessionFiles(in directory: String) -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        return contents
            .filter { $0.hasSuffix(".jsonl") }
            .map { "\(directory)/\($0)" }
    }

    private static func modificationDate(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: - JSONL Parsing

    /// Parse a session JSONL file to extract token usage and message counts.
    /// Only reads the last portion of the file for efficiency (tail-read).
    private static func parseSessionFile(_ path: String, workingDirectory: String) -> CLISessionInfo? {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return nil }

        var sessionId: String?
        var totalInput = 0
        var totalOutput = 0
        var messageCount = 0
        var toolUseCount = 0
        var lastTimestamp: Date?

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // Extract session ID
            if sessionId == nil, let sid = json["sessionId"] as? String {
                sessionId = sid
            }

            // Parse timestamp
            if let ts = json["timestamp"] as? String {
                lastTimestamp = isoFormatter.date(from: ts) ?? lastTimestamp
            }

            // Count messages
            let type = json["type"] as? String
            if type == "user" || type == "assistant" {
                messageCount += 1
            }

            // Extract token usage from assistant messages
            if type == "assistant",
               let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                totalInput += usage["input_tokens"] as? Int ?? 0
                totalInput += usage["cache_creation_input_tokens"] as? Int ?? 0
                totalInput += usage["cache_read_input_tokens"] as? Int ?? 0
                totalOutput += usage["output_tokens"] as? Int ?? 0
            }

            // Count tool uses
            if type == "assistant",
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                toolUseCount += content.filter { ($0["type"] as? String) == "tool_use" }.count
            }
        }

        guard let sid = sessionId else { return nil }

        // Use the last assistant message's input tokens as the current context size
        // (each turn's input_tokens represents the full context sent to the model)
        let lastInputTokens = lastAssistantInputTokens(lines: lines)

        return CLISessionInfo(
            sessionId: sid,
            workingDirectory: workingDirectory,
            totalInputTokens: lastInputTokens ?? totalInput,
            totalOutputTokens: totalOutput,
            messageCount: messageCount,
            toolUseCount: toolUseCount,
            lastActivity: lastTimestamp
        )
    }

    /// Get the input_tokens from the most recent assistant message.
    /// This represents the current context window usage more accurately
    /// than summing all turns (since each turn includes the full context).
    private static func lastAssistantInputTokens(lines: [Substring]) -> Int? {
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }

            let input = (usage["input_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"] as? Int ?? 0)

            if input > 0 { return input }
        }
        return nil
    }
}
