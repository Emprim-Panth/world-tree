import Foundation

struct ToolResult: Sendable {
    let content: String
    let isError: Bool
}

/// Executes tools locally on the filesystem and shell.
/// Runs off the main thread as an actor.
actor ToolExecutor {
    let workingDirectory: URL
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let maxOutputSize = 100_000 // 100KB cap on tool output

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    func execute(name: String, input: [String: AnyCodable]) async -> ToolResult {
        switch name {
        case "read_file": return readFile(input)
        case "write_file": return writeFile(input)
        case "edit_file": return editFile(input)
        case "bash": return await bash(input)
        case "glob": return await globFiles(input)
        case "grep": return await grepFiles(input)
        default: return ToolResult(content: "Unknown tool: \(name)", isError: true)
        }
    }

    // MARK: - read_file

    private func readFile(_ input: [String: AnyCodable]) -> ToolResult {
        guard let path = input["file_path"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: file_path", isError: true)
        }

        let resolvedPath = resolvePath(path)

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return ToolResult(content: "File not found: \(resolvedPath)", isError: true)
        }

        do {
            let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
            let allLines = content.components(separatedBy: "\n")

            let offset = (input["offset"]?.value as? Int).map { max(1, $0) } ?? 1
            let limit = input["limit"]?.value as? Int

            let startIndex = offset - 1
            guard startIndex < allLines.count else {
                return ToolResult(content: "Offset \(offset) exceeds file length (\(allLines.count) lines)", isError: true)
            }

            let endIndex: Int
            if let limit {
                endIndex = min(startIndex + limit, allLines.count)
            } else {
                endIndex = allLines.count
            }

            let slice = allLines[startIndex..<endIndex]
            var output = ""
            for (i, line) in slice.enumerated() {
                let lineNum = startIndex + i + 1
                let truncated = line.count > 2000 ? String(line.prefix(2000)) + "..." : line
                output += String(format: "%6d\t%@\n", lineNum, truncated)
            }

            if output.count > maxOutputSize {
                output = String(output.prefix(maxOutputSize)) + "\n[Output truncated at \(maxOutputSize) bytes]"
            }

            return ToolResult(content: output, isError: false)
        } catch {
            return ToolResult(content: "Error reading file: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - write_file

    private func writeFile(_ input: [String: AnyCodable]) -> ToolResult {
        guard let path = input["file_path"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: file_path", isError: true)
        }
        guard let content = input["content"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: content", isError: true)
        }

        let resolvedPath = resolvePath(path)

        do {
            // Create parent directories
            let dir = (resolvedPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )

            try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
            let bytes = content.utf8.count
            return ToolResult(content: "Wrote \(bytes) bytes to \(resolvedPath)", isError: false)
        } catch {
            return ToolResult(content: "Error writing file: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - edit_file

    private func editFile(_ input: [String: AnyCodable]) -> ToolResult {
        guard let path = input["file_path"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: file_path", isError: true)
        }
        guard let oldString = input["old_string"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: old_string", isError: true)
        }
        guard let newString = input["new_string"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: new_string", isError: true)
        }

        let resolvedPath = resolvePath(path)

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return ToolResult(content: "File not found: \(resolvedPath)", isError: true)
        }

        do {
            let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)

            // Count occurrences
            let occurrences = content.components(separatedBy: oldString).count - 1

            if occurrences == 0 {
                return ToolResult(
                    content: "old_string not found in \(resolvedPath). Make sure it matches exactly, including whitespace.",
                    isError: true
                )
            }
            if occurrences > 1 {
                return ToolResult(
                    content: "old_string found \(occurrences) times in \(resolvedPath). It must match exactly once. Add more surrounding context to make it unique.",
                    isError: true
                )
            }

            let updated = content.replacingOccurrences(of: oldString, with: newString)
            try updated.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

            return ToolResult(content: "Edited \(resolvedPath): replaced 1 occurrence", isError: false)
        } catch {
            return ToolResult(content: "Error editing file: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - bash

    private func bash(_ input: [String: AnyCodable]) async -> ToolResult {
        guard let command = input["command"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: command", isError: true)
        }

        let timeoutSecs = min((input["timeout"]?.value as? Int) ?? 120, 600)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", command]
        proc.currentDirectoryURL = workingDirectory

        // Full environment
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(home)/.local/bin:\(home)/.cortana/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        env["HOME"] = home
        proc.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            return ToolResult(content: "Failed to execute command: \(error.localizedDescription)", isError: true)
        }

        // Timeout enforcement
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeoutSecs) * 1_000_000_000)
            if proc.isRunning {
                proc.terminate()
            }
        }

        proc.waitUntilExit()
        timeoutTask.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        var output = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        if !stderr.isEmpty {
            output += "\n[stderr]\n\(stderr)"
        }

        if output.count > maxOutputSize {
            output = String(output.prefix(maxOutputSize)) + "\n[Output truncated at \(maxOutputSize) bytes]"
        }

        let exitCode = proc.terminationStatus
        if exitCode != 0 {
            output += "\n[exit code: \(exitCode)]"
        }

        return ToolResult(content: output, isError: exitCode != 0)
    }

    // MARK: - glob

    private func globFiles(_ input: [String: AnyCodable]) async -> ToolResult {
        guard let pattern = input["pattern"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: pattern", isError: true)
        }

        let searchPath = (input["path"]?.value as? String).map { resolvePath($0) }
            ?? workingDirectory.path

        // Use find + shell glob via bash for robust pattern matching
        let command: String
        if pattern.contains("**") {
            // Recursive glob — use find with name matching
            let namePattern = (pattern as NSString).lastPathComponent
            let basePath = pattern.contains("/")
                ? "\(searchPath)/\((pattern as NSString).deletingLastPathComponent.replacingOccurrences(of: "**", with: ""))"
                : searchPath
            command = "find '\(basePath)' -name '\(namePattern)' -type f 2>/dev/null | head -500 | sort"
        } else {
            command = "find '\(searchPath)' -name '\(pattern)' -type f 2>/dev/null | head -500 | sort"
        }

        let result = await bash(["command": AnyCodable(command)])
        if result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ToolResult(content: "No files found matching '\(pattern)' in \(searchPath)", isError: false)
        }
        return ToolResult(content: result.content, isError: false)
    }

    // MARK: - grep

    private func grepFiles(_ input: [String: AnyCodable]) async -> ToolResult {
        guard let pattern = input["pattern"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: pattern", isError: true)
        }

        let searchPath = (input["path"]?.value as? String).map { resolvePath($0) }
            ?? workingDirectory.path

        var args = ["-rn"]

        if let include = input["include"]?.value as? String {
            args.append("--include=\(include)")
        }

        if let context = input["context"]?.value as? Int, context > 0 {
            args.append("-C")
            args.append("\(context)")
        }

        // Escape the pattern for shell
        let escapedPattern = pattern.replacingOccurrences(of: "'", with: "'\\''")
        let command = "grep \(args.joined(separator: " ")) '\(escapedPattern)' '\(searchPath)' 2>/dev/null | head -200"

        let result = await bash(["command": AnyCodable(command)])
        if result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ToolResult(content: "No matches found for '\(pattern)' in \(searchPath)", isError: false)
        }
        return ToolResult(content: result.content, isError: false)
    }

    // MARK: - Path Resolution

    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return path
        }
        if path.hasPrefix("~") {
            return path.replacingOccurrences(of: "~", with: home)
        }
        return workingDirectory.appendingPathComponent(path).path
    }
}
