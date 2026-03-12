import Foundation
import ScreenCaptureKit
import CoreGraphics
import ImageIO

struct ToolResult: Sendable {
    let content: String
    let isError: Bool
}

/// Thread-safe pipe data accumulator. Used with readabilityHandler to drain
/// pipe output incrementally, preventing the 64KB pipe buffer deadlock that
/// occurs when a process writes more than the OS pipe buffer can hold.
final class PipeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()

    func append(_ chunk: Data) {
        lock.withLock { _data.append(chunk) }
    }

    var data: Data {
        lock.withLock { _data }
    }
}

/// Executes tools locally on the filesystem and shell.
/// Runs off the main thread as an actor.
actor ToolExecutor {
    let workingDirectory: URL
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let maxOutputSize = 100_000 // 100KB cap on tool output

    // Pre-compiled regex patterns — initialized once, never crash at call sites
    private static let xcodeDiagnosticPattern = try! NSRegularExpression(
        pattern: #"^(.+):(\d+):(\d+): (error|warning): (.+)$"#,
        options: .anchorsMatchLines
    )
    private static let xcodeTestPattern = try! NSRegularExpression(
        pattern: #"Test Case '-\[(.+?) (.+?)\]' (passed|failed) \((\d+\.\d+) seconds\)"#,
        options: .anchorsMatchLines
    )
    private static let cargoTestPattern = try! NSRegularExpression(
        pattern: #"test (.+?) \.\.\. (ok|FAILED|ignored)"#,
        options: .anchorsMatchLines
    )

    /// tmux session name for the active branch — when set, bash tool calls route through
    /// the visible terminal so Evan can watch execution live and interact if needed.
    let tmuxSessionName: String?

    /// Canvas session ID — used by search_conversation to scope FTS queries.
    let sessionId: String?

    init(workingDirectory: URL, tmuxSessionName: String? = nil, sessionId: String? = nil) {
        self.workingDirectory = workingDirectory
        self.tmuxSessionName = tmuxSessionName
        self.sessionId = sessionId
    }

    func execute(name: String, input: [String: AnyCodable]) async -> ToolResult {
        switch name {
        case "read_file": return readFile(input)
        case "write_file": return await writeFile(input)
        case "edit_file": return await editFile(input)
        case "bash":
            // Route through tmux when a session is available — Evan watches live
            if let session = tmuxSessionName {
                return await bashViaTmux(input, sessionName: session)
            }
            return await bash(input)
        case "glob": return await globFiles(input)
        case "grep": return await grepFiles(input)
        case "build_project": return await buildProject(input)
        case "run_tests": return await runTests(input)
        case "checkpoint_create": return await checkpointCreate(input)
        case "checkpoint_revert": return await checkpointRevert(input)
        case "checkpoint_list": return await checkpointList(input)
        case "background_run": return await backgroundRun(input)
        case "list_terminals": return await listTerminals(input)
        case "terminal_output": return await terminalOutput(input)
        case "capture_screenshot": return await captureScreenshot(input)
        case "search_conversation": return await executeSearchConversation(input)
        case "git_status": return await gitStatus(input)
        case "git_log": return await gitLog(input)
        case "git_diff": return await gitDiff(input)
        case "find_unused_code": return await findUnusedCode(input)
        case "lint_check": return await lintCheck(input)
        case "simulator_list": return await simulatorList(input)
        case "simulator_build_run": return await simulatorBuildRun(input)
        case "simulator_app_manage": return await simulatorAppManage(input)
        case "simulator_screenshot": return await simulatorScreenshot(input)
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

    private func writeFile(_ input: [String: AnyCodable]) async -> ToolResult {
        guard let path = input["file_path"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: file_path", isError: true)
        }
        guard let content = input["content"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: content", isError: true)
        }

        let resolvedPath = resolvePath(path)

        // Diff review: show before/after and wait for user approval when enabled
        if UserDefaults.standard.bool(forKey: AppConstants.fileWriteReviewEnabledKey) {
            let oldContent = (try? String(contentsOfFile: resolvedPath, encoding: .utf8)) ?? ""
            let approved = await ApprovalCoordinator.shared.requestFileDiffApproval(
                filePath: resolvedPath,
                oldContent: oldContent,
                newContent: content
            )
            if !approved {
                return ToolResult(content: "File write rejected by user: \(resolvedPath)", isError: true)
            }
        }

        do {
            // Create parent directories
            let dir = (resolvedPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )

            try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
            let bytes = content.utf8.count
            var result = "Wrote \(bytes) bytes to \(resolvedPath)"

            // Syntax validation
            let syntaxResult = await syntaxCheck(resolvedPath)
            if !syntaxResult.isEmpty {
                result += "\n\(syntaxResult)"
            }

            return ToolResult(content: result, isError: false)
        } catch {
            return ToolResult(content: "Error writing file: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - edit_file

    private func editFile(_ input: [String: AnyCodable]) async -> ToolResult {
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

            // Diff review: show before/after and wait for user approval when enabled
            if UserDefaults.standard.bool(forKey: AppConstants.fileWriteReviewEnabledKey) {
                let approved = await ApprovalCoordinator.shared.requestFileDiffApproval(
                    filePath: resolvedPath,
                    oldContent: content,
                    newContent: updated
                )
                if !approved {
                    return ToolResult(content: "File edit rejected by user: \(resolvedPath)", isError: true)
                }
            }

            try updated.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

            var result = "Edited \(resolvedPath): replaced 1 occurrence"

            // Syntax validation
            let syntaxResult = await syntaxCheck(resolvedPath)
            if !syntaxResult.isEmpty {
                result += "\n\(syntaxResult)"
            }

            return ToolResult(content: result, isError: false)
        } catch {
            return ToolResult(content: "Error editing file: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - bash

    private func bash(_ input: [String: AnyCodable]) async -> ToolResult {
        guard let command = input["command"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: command", isError: true)
        }

        // Security gate — check for dangerous patterns
        let plainInput = input.mapValues { $0.value as Any }
        let assessment = ToolGuard.assess(toolName: "bash", input: plainInput)
        if assessment.requiresApproval {
            wtLog("[ToolGuard] Approval required: \(assessment.reason) — command: \(command.prefix(100))")
            let approved = await ApprovalCoordinator.shared.requestApproval(
                assessment: assessment,
                command: command
            )
            guard approved else {
                return ToolResult(content: "[Security Gate] Operation denied.", isError: true)
            }
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

        // Drain pipes via readabilityHandler BEFORE run to avoid pipe buffer deadlock.
        // If a process writes >64KB to stdout/stderr, the pipe buffer fills and the
        // process blocks forever waiting for a reader — deadlocking the cooperative thread.
        let stdoutAccum = PipeAccumulator()
        let stderrAccum = PipeAccumulator()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                stdoutAccum.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                stderrAccum.append(data)
            }
        }

        do {
            try proc.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return ToolResult(content: "Failed to execute command: \(error.localizedDescription)", isError: true)
        }

        // Async wait with timeout — avoids blocking the cooperative thread pool
        let exitCode: Int32 = await withCheckedContinuation { continuation in
            let timeoutTask = DispatchWorkItem {
                if proc.isRunning { proc.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSecs), execute: timeoutTask)

            proc.terminationHandler = { process in
                timeoutTask.cancel()
                continuation.resume(returning: process.terminationStatus)
            }
        }

        // Pipes are already drained by readabilityHandler — just collect the data
        let stdoutData = stdoutAccum.data
        let stderrData = stderrAccum.data

        var output = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        if !stderr.isEmpty {
            output += "\n[stderr]\n\(stderr)"
        }

        if output.count > maxOutputSize {
            output = String(output.prefix(maxOutputSize)) + "\n[Output truncated at \(maxOutputSize) bytes]"
        }

        if exitCode != 0 {
            output += "\n[exit code: \(exitCode)]"
        }

        return ToolResult(content: output, isError: exitCode != 0)
    }

    // MARK: - bash via tmux

    /// Run a bash command inside the branch's live tmux session.
    /// The command is visible in the terminal — Evan can watch it execute and interact.
    /// Output is captured via a temp file so the result is returned to Cortana as normal.
    private func bashViaTmux(_ input: [String: AnyCodable], sessionName: String) async -> ToolResult {
        guard let command = input["command"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: command", isError: true)
        }

        // Security gate — same as direct bash
        let plainInput = input.mapValues { $0.value as Any }
        let assessment = ToolGuard.assess(toolName: "bash", input: plainInput)
        if assessment.requiresApproval {
            wtLog("[ToolGuard] Approval required: \(assessment.reason) — command: \(command.prefix(100))")
            let approved = await ApprovalCoordinator.shared.requestApproval(
                assessment: assessment,
                command: command
            )
            guard approved else {
                return ToolResult(content: "[Security Gate] Operation denied.", isError: true)
            }
        }

        let timeoutSecs = min((input["timeout"]?.value as? Int) ?? 120, 600)
        let uuid = UUID().uuidString
        let scriptPath = "/tmp/canvas-\(uuid).sh"
        let outputPath = "/tmp/canvas-\(uuid).out"
        let exitPath   = "/tmp/canvas-\(uuid).exit"

        // Ensure temp files are always cleaned up, even on early return or error
        defer {
            try? FileManager.default.removeItem(atPath: scriptPath)
            try? FileManager.default.removeItem(atPath: outputPath)
            try? FileManager.default.removeItem(atPath: exitPath)
        }

        // Write a self-contained script that captures output and exit code.
        // Uses `tmux wait-for -S` to signal completion — the Swift side blocks on
        // `tmux wait-for` instead of polling the filesystem every 200ms.
        let waitChannel = "done-\(uuid)"
        let script = """
            #!/bin/bash
            export PATH="\(home)/.local/bin:\(home)/.cortana/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
            export HOME="\(home)"
            cd '\(workingDirectory.path.replacingOccurrences(of: "'", with: "'\\''"))'
            (\(command)) > '\(outputPath)' 2>&1
            echo $? > '\(exitPath)'
            \(tmuxExecutable) wait-for -S '\(waitChannel)'
            """
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755 as NSNumber], ofItemAtPath: scriptPath)
        } catch {
            wtLog("[ToolExecutor] bashViaTmux: failed to write script — \(error)")
            return await bash(input) // fallback to direct execution
        }

        // Run the script inside the tmux session
        let sendProc = Process()
        sendProc.executableURL = URL(fileURLWithPath: tmuxExecutable)
        sendProc.arguments = ["send-keys", "-t", sessionName, "bash '\(scriptPath)'", "Enter"]
        sendProc.standardOutput = FileHandle.nullDevice
        sendProc.standardError = FileHandle.nullDevice
        do {
            try sendProc.run()
            // Async wait — avoids blocking the cooperative thread pool
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                sendProc.terminationHandler = { _ in cont.resume() }
            }
        } catch {
            wtLog("[ToolExecutor] bashViaTmux: failed to send keys — \(error)")
        }

        // Event-driven completion: `tmux wait-for` blocks until the script
        // signals the channel via `tmux wait-for -S`. No polling, instant detection.
        // Falls back to timeout if the command hangs or tmux wait-for fails.
        let waitCompleted = await withTaskGroup(of: Bool.self) { group in
            // Task 1: wait-for channel signal (blocks until script completes)
            group.addTask {
                let waitProc = Process()
                waitProc.executableURL = URL(fileURLWithPath: tmuxExecutable)
                waitProc.arguments = ["wait-for", waitChannel]
                waitProc.standardOutput = FileHandle.nullDevice
                waitProc.standardError = FileHandle.nullDevice
                do {
                    try waitProc.run()
                    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                        waitProc.terminationHandler = { proc in
                            cont.resume(returning: proc.terminationStatus == 0)
                        }
                    }
                } catch {
                    return false
                }
            }

            // Task 2: timeout guard
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSecs) * 1_000_000_000)
                return false
            }

            // First result wins — if timeout fires first, we cancel the wait-for
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        if !waitCompleted || !FileManager.default.fileExists(atPath: exitPath) {
            wtLog("[ToolExecutor] bashViaTmux: command timed out after \(timeoutSecs)s — sending SIGINT to tmux session")
            // Kill the running script in tmux
            let killProc = Process()
            killProc.executableURL = URL(fileURLWithPath: tmuxExecutable)
            killProc.arguments = ["send-keys", "-t", sessionName, "C-c", ""]
            killProc.standardOutput = FileHandle.nullDevice
            killProc.standardError = FileHandle.nullDevice
            try? killProc.run()
            killProc.waitUntilExit()
            // Also unblock any lingering wait-for listener
            let unblockProc = Process()
            unblockProc.executableURL = URL(fileURLWithPath: tmuxExecutable)
            unblockProc.arguments = ["wait-for", "-S", waitChannel]
            unblockProc.standardOutput = FileHandle.nullDevice
            unblockProc.standardError = FileHandle.nullDevice
            try? unblockProc.run()
        }

        // Read results
        var output = (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? ""
        let exitStr = (try? String(contentsOfFile: exitPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
        let exitCode = Int32(exitStr) ?? 1

        if output.count > maxOutputSize {
            output = String(output.prefix(maxOutputSize)) + "\n[Output truncated at \(maxOutputSize) bytes]"
        }
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

    // MARK: - build_project

    private func buildProject(_ input: [String: AnyCodable]) async -> ToolResult {
        let projectPath = (input["path"]?.value as? String).map { resolvePath($0) }
            ?? workingDirectory.path
        let fm = FileManager.default

        // Auto-detect project type and build
        if let scheme = input["scheme"]?.value as? String {
            return await xcodeBuild(path: projectPath, scheme: scheme)
        }

        // Check for Xcode project
        if let contents = try? fm.contentsOfDirectory(atPath: projectPath),
           contents.contains(where: { $0.hasSuffix(".xcodeproj") }) {
            let scheme = input["scheme"]?.value as? String
                ?? detectXcodeScheme(at: projectPath)
            if let scheme {
                return await xcodeBuild(path: projectPath, scheme: scheme)
            }
            return ToolResult(content: "Xcode project found but no scheme detected. Specify scheme parameter.", isError: true)
        }

        // Check for Cargo.toml
        if fm.fileExists(atPath: "\(projectPath)/Cargo.toml") {
            return await cargoBuild(path: projectPath)
        }

        // Check for package.json
        if fm.fileExists(atPath: "\(projectPath)/package.json") {
            return await npmBuild(path: projectPath)
        }

        // Check for Package.swift (SPM)
        if fm.fileExists(atPath: "\(projectPath)/Package.swift") {
            let result = await bash(["command": AnyCodable("cd '\(projectPath)' && swift build 2>&1")])
            return parseSwiftBuildErrors(result.content)
        }

        return ToolResult(content: "No recognized project type found in \(projectPath)", isError: true)
    }

    private func xcodeBuild(path: String, scheme: String) async -> ToolResult {
        let cmd = "cd '\(path)' && xcodebuild -scheme '\(scheme)' build 2>&1"
        let result = await bash(["command": AnyCodable(cmd), "timeout": AnyCodable(300)])
        return parseXcodeBuildErrors(result.content)
    }

    private func cargoBuild(path: String) async -> ToolResult {
        let cmd = "cd '\(path)' && cargo build --message-format=json 2>&1"
        let result = await bash(["command": AnyCodable(cmd), "timeout": AnyCodable(300)])
        return parseCargoBuildErrors(result.content)
    }

    private func npmBuild(path: String) async -> ToolResult {
        let cmd = "cd '\(path)' && npm run build 2>&1"
        let result = await bash(["command": AnyCodable(cmd), "timeout": AnyCodable(120)])
        return ToolResult(content: result.content, isError: result.isError)
    }

    private func detectXcodeScheme(at path: String) -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path),
              let xcodeproj = contents.first(where: { $0.hasSuffix(".xcodeproj") }) else {
            return nil
        }
        // Scheme name is usually the project name minus .xcodeproj
        return (xcodeproj as NSString).deletingPathExtension
    }

    private func parseXcodeBuildErrors(_ output: String) -> ToolResult {
        var errors: [[String: String]] = []
        let pattern = Self.xcodeDiagnosticPattern
        let range = NSRange(output.startIndex..., in: output)

        for match in pattern.matches(in: output, range: range) {
            guard match.numberOfRanges == 6 else { continue }
            let file = String(output[Range(match.range(at: 1), in: output)!])
            let line = String(output[Range(match.range(at: 2), in: output)!])
            let col = String(output[Range(match.range(at: 3), in: output)!])
            let severity = String(output[Range(match.range(at: 4), in: output)!])
            let message = String(output[Range(match.range(at: 5), in: output)!])
            errors.append(["file": file, "line": line, "column": col, "severity": severity, "message": message])
        }

        let succeeded = output.contains("BUILD SUCCEEDED")

        if errors.isEmpty {
            return ToolResult(
                content: succeeded ? "BUILD SUCCEEDED (0 errors, 0 warnings)" : output,
                isError: !succeeded
            )
        }

        let errorCount = errors.filter { $0["severity"] == "error" }.count
        let warnCount = errors.filter { $0["severity"] == "warning" }.count
        let status = succeeded ? "BUILD SUCCEEDED" : "BUILD FAILED"
        let json = (try? JSONSerialization.data(withJSONObject: errors, options: .prettyPrinted))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return ToolResult(
            content: "\(status) (\(errorCount) errors, \(warnCount) warnings)\n\(json)",
            isError: !succeeded
        )
    }

    private func parseCargoBuildErrors(_ output: String) -> ToolResult {
        var errors: [[String: String]] = []

        for line in output.components(separatedBy: "\n") {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["reason"] as? String == "compiler-message",
                  let msg = json["message"] as? [String: Any] else { continue }

            let level = msg["level"] as? String ?? "error"
            let message = msg["message"] as? String ?? ""
            let spans = (msg["spans"] as? [[String: Any]])?.first

            var entry: [String: String] = ["severity": level, "message": message]
            if let file = spans?["file_name"] as? String { entry["file"] = file }
            if let lineStart = spans?["line_start"] as? Int { entry["line"] = "\(lineStart)" }
            if let colStart = spans?["column_start"] as? Int { entry["column"] = "\(colStart)" }
            errors.append(entry)
        }

        let succeeded = !output.contains("error[") && !output.contains("could not compile")
        let errorCount = errors.filter { $0["severity"] == "error" }.count
        let warnCount = errors.filter { $0["severity"] == "warning" }.count

        if errors.isEmpty {
            return ToolResult(
                content: succeeded ? "BUILD SUCCEEDED" : output,
                isError: !succeeded
            )
        }

        let json = (try? JSONSerialization.data(withJSONObject: errors, options: .prettyPrinted))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return ToolResult(
            content: "\(succeeded ? "BUILD SUCCEEDED" : "BUILD FAILED") (\(errorCount) errors, \(warnCount) warnings)\n\(json)",
            isError: !succeeded
        )
    }

    private func parseSwiftBuildErrors(_ output: String) -> ToolResult {
        // Same format as Xcode
        return parseXcodeBuildErrors(output)
    }

    // MARK: - run_tests

    private func runTests(_ input: [String: AnyCodable]) async -> ToolResult {
        let projectPath = (input["path"]?.value as? String).map { resolvePath($0) }
            ?? workingDirectory.path
        let filter = input["filter"]?.value as? String
        let fm = FileManager.default

        // Xcode project
        if let contents = try? fm.contentsOfDirectory(atPath: projectPath),
           contents.contains(where: { $0.hasSuffix(".xcodeproj") }) {
            let scheme = input["scheme"]?.value as? String
                ?? detectXcodeScheme(at: projectPath)
            if let scheme {
                var cmd = "cd '\(projectPath)' && xcodebuild test -scheme '\(scheme)'"
                if let filter { cmd += " -only-testing:'\(filter)'" }
                cmd += " 2>&1"
                let result = await bash(["command": AnyCodable(cmd), "timeout": AnyCodable(600)])
                return parseXcodeTestResults(result.content)
            }
        }

        // Cargo
        if fm.fileExists(atPath: "\(projectPath)/Cargo.toml") {
            var cmd = "cd '\(projectPath)' && cargo test"
            if let filter { cmd += " '\(filter)'" }
            cmd += " 2>&1"
            let result = await bash(["command": AnyCodable(cmd), "timeout": AnyCodable(300)])
            return parseCargoTestResults(result.content)
        }

        // SPM
        if fm.fileExists(atPath: "\(projectPath)/Package.swift") {
            var cmd = "cd '\(projectPath)' && swift test"
            if let filter { cmd += " --filter '\(filter)'" }
            cmd += " 2>&1"
            let result = await bash(["command": AnyCodable(cmd), "timeout": AnyCodable(300)])
            return parseXcodeTestResults(result.content) // Same format
        }

        // npm
        if fm.fileExists(atPath: "\(projectPath)/package.json") {
            let cmd = "cd '\(projectPath)' && npm test 2>&1"
            let result = await bash(["command": AnyCodable(cmd), "timeout": AnyCodable(120)])
            return ToolResult(content: result.content, isError: result.isError)
        }

        return ToolResult(content: "No recognized test framework in \(projectPath)", isError: true)
    }

    private func parseXcodeTestResults(_ output: String) -> ToolResult {
        var tests: [[String: String]] = []

        // Pattern: Test Case '-[Bundle.Class testMethod]' passed (0.001 seconds).
        let passPattern = Self.xcodeTestPattern
        let range = NSRange(output.startIndex..., in: output)
        for match in passPattern.matches(in: output, range: range) {
            guard match.numberOfRanges == 5 else { continue }
            let className = String(output[Range(match.range(at: 1), in: output)!])
            let methodName = String(output[Range(match.range(at: 2), in: output)!])
            let status = String(output[Range(match.range(at: 3), in: output)!])
            let duration = String(output[Range(match.range(at: 4), in: output)!])
            tests.append([
                "test_name": "\(className).\(methodName)",
                "status": status == "passed" ? "pass" : "fail",
                "duration": duration,
            ])
        }

        let succeeded = output.contains("Test Suite") && output.contains("passed")
        let passCount = tests.filter { $0["status"] == "pass" }.count
        let failCount = tests.filter { $0["status"] == "fail" }.count

        if tests.isEmpty {
            return ToolResult(content: output, isError: !succeeded)
        }

        let json = (try? JSONSerialization.data(withJSONObject: tests, options: .prettyPrinted))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return ToolResult(
            content: "TESTS: \(passCount) passed, \(failCount) failed\n\(json)",
            isError: failCount > 0
        )
    }

    private func parseCargoTestResults(_ output: String) -> ToolResult {
        var tests: [[String: String]] = []

        // Pattern: test module::test_name ... ok/FAILED
        let testPattern = Self.cargoTestPattern
        let range = NSRange(output.startIndex..., in: output)
        for match in testPattern.matches(in: output, range: range) {
            guard match.numberOfRanges == 3 else { continue }
            let name = String(output[Range(match.range(at: 1), in: output)!])
            let result = String(output[Range(match.range(at: 2), in: output)!])
            let status: String
            switch result {
            case "ok": status = "pass"
            case "FAILED": status = "fail"
            default: status = "skip"
            }
            tests.append(["test_name": name, "status": status])
        }

        let succeeded = output.contains("test result: ok")
        let passCount = tests.filter { $0["status"] == "pass" }.count
        let failCount = tests.filter { $0["status"] == "fail" }.count
        let skipCount = tests.filter { $0["status"] == "skip" }.count

        if tests.isEmpty {
            return ToolResult(content: output, isError: !succeeded)
        }

        let json = (try? JSONSerialization.data(withJSONObject: tests, options: .prettyPrinted))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return ToolResult(
            content: "TESTS: \(passCount) passed, \(failCount) failed, \(skipCount) skipped\n\(json)",
            isError: failCount > 0
        )
    }

    // MARK: - Syntax Validation

    private func syntaxCheck(_ filePath: String) async -> String {
        let ext = (filePath as NSString).pathExtension.lowercased()
        let cmd: String?

        switch ext {
        case "swift":
            cmd = "swiftc -typecheck '\(filePath)' 2>&1"
        case "py":
            cmd = "python3 -m py_compile '\(filePath)' 2>&1"
        case "ts", "tsx":
            // Check if tsc is available
            cmd = "npx tsc --noEmit '\(filePath)' 2>&1"
        case "js", "jsx":
            // Basic syntax check via node
            cmd = "node --check '\(filePath)' 2>&1"
        default:
            cmd = nil
        }

        guard let cmd else { return "" }

        let result = await bash(["command": AnyCodable(cmd), "timeout": AnyCodable(30)])

        if result.isError {
            let lines = result.content.components(separatedBy: "\n")
            let errorLines = lines.filter {
                $0.contains("error") || $0.contains("Error") || $0.contains("warning")
            }.prefix(5)

            if errorLines.isEmpty {
                return "[Syntax check: errors found]\n\(String(result.content.prefix(300)))"
            }
            return "[Syntax check: \(errorLines.count) issue(s)]\n\(errorLines.joined(separator: "\n"))"
        }

        return "[Syntax check: OK]"
    }

    // MARK: - Checkpoints

    private func checkpointCreate(_ input: [String: AnyCodable]) async -> ToolResult {
        guard let name = input["name"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: name", isError: true)
        }

        // Check if we're in a git repo
        let gitCheck = await bash(["command": AnyCodable("git rev-parse --git-dir 2>/dev/null")])
        guard !gitCheck.isError else {
            return ToolResult(content: "Not in a git repository. Checkpoints require git.", isError: true)
        }

        let stashName = "canvas-checkpoint: \(name)"
        let result = await bash(["command": AnyCodable("git stash push -m '\(stashName)' --include-untracked 2>&1")])

        if result.content.contains("No local changes to save") {
            return ToolResult(content: "No changes to checkpoint (working tree is clean)", isError: false)
        }

        // Immediately re-apply so working tree isn't disturbed
        let _ = await bash(["command": AnyCodable("git stash apply 2>&1")])

        if result.isError {
            return ToolResult(content: "Checkpoint failed: \(result.content)", isError: true)
        }

        return ToolResult(content: "Checkpoint created: \(name)\n(Changes preserved in stash and working tree)", isError: false)
    }

    private func checkpointRevert(_ input: [String: AnyCodable]) async -> ToolResult {
        let index = (input["index"]?.value as? Int) ?? 0

        // List canvas checkpoints to verify index
        let listResult = await bash(["command": AnyCodable("git stash list 2>&1")])
        guard !listResult.isError else {
            return ToolResult(content: "Failed to list stashes: \(listResult.content)", isError: true)
        }

        let stashes = listResult.content.components(separatedBy: "\n")
            .filter { $0.contains("canvas-checkpoint:") }

        if stashes.isEmpty {
            return ToolResult(content: "No canvas checkpoints found", isError: false)
        }

        // Find the actual stash index for the Nth canvas checkpoint
        let allStashes = listResult.content.components(separatedBy: "\n")
        var canvasIndex = 0
        var targetStashIndex: Int?

        for (i, stash) in allStashes.enumerated() {
            if stash.contains("canvas-checkpoint:") {
                if canvasIndex == index {
                    targetStashIndex = i
                    break
                }
                canvasIndex += 1
            }
        }

        guard let stashIdx = targetStashIndex else {
            return ToolResult(content: "Checkpoint index \(index) not found. Available: \(stashes.count) checkpoints", isError: true)
        }

        let result = await bash(["command": AnyCodable("git checkout -- . && git stash apply stash@{\(stashIdx)} 2>&1")])
        let checkpointLabel = stashes.indices.contains(index) ? stashes[index] : "checkpoint \(index)"
        return ToolResult(
            content: result.isError ? "Revert failed: \(result.content)" : "Reverted to \(checkpointLabel)",
            isError: result.isError
        )
    }

    private func checkpointList(_ input: [String: AnyCodable]) async -> ToolResult {
        let result = await bash(["command": AnyCodable("git stash list 2>&1")])
        guard !result.isError else {
            return ToolResult(content: "Failed to list stashes: \(result.content)", isError: true)
        }

        let canvasStashes = result.content.components(separatedBy: "\n")
            .filter { $0.contains("canvas-checkpoint:") }

        if canvasStashes.isEmpty {
            return ToolResult(content: "No canvas checkpoints found", isError: false)
        }

        var output = "Cortana Checkpoints:\n"
        for (i, stash) in canvasStashes.enumerated() {
            output += "  [\(i)] \(stash)\n"
        }
        return ToolResult(content: output, isError: false)
    }

    // MARK: - background_run

    private func backgroundRun(_ input: [String: AnyCodable]) async -> ToolResult {
        guard let command = input["command"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: command", isError: true)
        }

        let cwd = (input["path"]?.value as? String).map { resolvePath($0) }
            ?? workingDirectory.path

        let jobId = await JobQueue.shared.enqueue(
            command: command,
            workingDirectory: cwd
        )

        return ToolResult(
            content: "Job started in background.\nJob ID: \(jobId)\nCommand: \(command)\nYou'll get a macOS notification when it completes.\nUse bash to check: sqlite3 ~/.cortana/... or check the job output later.",
            isError: false
        )
    }

    // MARK: - list_terminals

    private func listTerminals(_ input: [String: AnyCodable]) async -> ToolResult {
        var output = ""

        // 1. Discover tmux sessions
        let tmuxResult = await bash(["command": AnyCodable(
            "tmux list-sessions -F '#{session_name} (#{session_windows} windows, #{session_activity})' 2>/dev/null"
        )])
        if !tmuxResult.isError && !tmuxResult.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output += "## tmux Sessions\n\(tmuxResult.content)\n"

            // Get pane details for each session
            let panesResult = await bash(["command": AnyCodable(
                "tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} [#{pane_width}x#{pane_height}] #{pane_current_command}' 2>/dev/null"
            )])
            if !panesResult.isError && !panesResult.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output += "\n## tmux Panes\n\(panesResult.content)\n"
            }
        } else {
            output += "## tmux: No sessions found\n"
        }

        // 2. Detect running development processes
        let psResult = await bash(["command": AnyCodable(
            "ps aux | grep -E '(xcodebuild|cargo|swift build|npm|node|python|bun|ruby|go build|rustc)' | grep -v grep | awk '{print $2, $11, $12, $13}' 2>/dev/null"
        )])
        if !psResult.isError && !psResult.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output += "\n## Running Dev Processes\n\(psResult.content)\n"
        }

        // 3. Canvas background jobs
        let activeJobs = JobQueue.shared.activeJobs()
        if !activeJobs.isEmpty {
            output += "\n## Background Jobs\n"
            for job in activeJobs {
                output += "  [\(job.status.rawValue)] \(job.displayCommand) (id: \(job.id.prefix(8)))\n"
            }
        }

        if output.isEmpty {
            return ToolResult(content: "No active terminals or processes found", isError: false)
        }
        return ToolResult(content: output, isError: false)
    }

    // MARK: - terminal_output

    private func terminalOutput(_ input: [String: AnyCodable]) async -> ToolResult {
        guard let session = input["session"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: session", isError: true)
        }

        let pane = input["pane"]?.value as? String
        let lines = min((input["lines"]?.value as? Int) ?? 50, 500)

        // Sanitize session/pane to prevent single-quote injection in shell command.
        // tmux session names cannot contain single quotes — strip them.
        let safeSession = session.replacingOccurrences(of: "'", with: "")
        let safePaneTarget: String
        if let p = pane {
            let safePane = p.replacingOccurrences(of: "'", with: "")
            safePaneTarget = "\(safeSession):\(safePane)"
        } else {
            safePaneTarget = safeSession
        }
        let cmd = "tmux capture-pane -t '\(safePaneTarget)' -p -S -\(lines) 2>&1"

        let result = await bash(["command": AnyCodable(cmd)])
        if result.isError {
            return ToolResult(content: "Failed to capture pane: \(result.content)", isError: true)
        }

        return ToolResult(
            content: "Output from tmux pane '\(safePaneTarget)' (last \(lines) lines):\n\(result.content)",
            isError: false
        )
    }

    // MARK: - capture_screenshot

    private func captureScreenshot(_ input: [String: AnyCodable]) async -> ToolResult {
        let target = input["target"]?.value as? String ?? "simulator"
        let deviceId = input["device_id"]?.value as? String

        // Ensure output directory exists
        let screenshotsDir = "\(home)/.cortana/screenshots"
        try? FileManager.default.createDirectory(atPath: screenshotsDir, withIntermediateDirectories: true)

        let filename = "\(UUID().uuidString).png"
        let outputPath = "\(screenshotsDir)/\(filename)"

        if target == "simulator" {
            // iOS Simulator — use simctl (doesn't need Screen Recording TCC)
            let command: String
            if let deviceId {
                let safeId = deviceId.filter { $0.isHexDigit || $0 == "-" }
                command = "xcrun simctl io '\(safeId)' screenshot '\(outputPath)' 2>&1"
            } else {
                command = "xcrun simctl io booted screenshot '\(outputPath)' 2>&1"
            }

            let result = await bash(["command": AnyCodable(command)])
            if result.isError {
                return ToolResult(content: "Failed to capture screenshot: \(result.content)", isError: true)
            }

            guard FileManager.default.fileExists(atPath: outputPath) else {
                return ToolResult(content: "Screenshot command ran but file not found at \(outputPath). Output: \(result.content)", isError: true)
            }

            return ToolResult(content: "Screenshot captured (iOS Simulator).\nFile: \(outputPath)", isError: false)
        } else {
            // macOS screen — use ScreenCaptureKit in-process (inherits World Tree's TCC grant)
            // Guard: never call SCShareableContent without a grant — it triggers the OS prompt.
            guard CGPreflightScreenCaptureAccess() else {
                return ToolResult(
                    content: "Screen Recording permission not granted. Grant it in System Settings → Privacy & Security → Screen Recording → World Tree, then retry.",
                    isError: true
                )
            }
            let bundleId = input["bundle_id"]?.value as? String
            do {
                let content = try await SCShareableContent.current
                let config = SCStreamConfiguration()
                config.showsCursor = false

                let cgImage: CGImage
                if let bid = bundleId,
                   let window = content.windows.first(where: {
                       $0.owningApplication?.bundleIdentifier == bid && $0.isOnScreen
                   }) {
                    config.width = max(1, Int(window.frame.width * 2))
                    config.height = max(1, Int(window.frame.height * 2))
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                } else if let display = content.displays.first {
                    config.width = display.width
                    config.height = display.height
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                } else {
                    return ToolResult(content: "No display available for screenshot", isError: true)
                }

                // Write PNG
                let url = URL(fileURLWithPath: outputPath) as CFURL
                guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
                    return ToolResult(content: "Failed to create image destination at \(outputPath)", isError: true)
                }
                CGImageDestinationAddImage(dest, cgImage, nil)
                guard CGImageDestinationFinalize(dest) else {
                    return ToolResult(content: "Failed to write screenshot to \(outputPath)", isError: true)
                }

                return ToolResult(
                    content: "Screenshot captured (Mac screen, \(cgImage.width)×\(cgImage.height)).\nFile: \(outputPath)",
                    isError: false
                )
            } catch {
                return ToolResult(
                    content: "Screenshot failed: \(error.localizedDescription). Ensure Screen Recording is granted in System Settings > Privacy & Security > Screen Recording.",
                    isError: true
                )
            }
        }
    }

    // MARK: - search_conversation

    private func executeSearchConversation(_ input: [String: AnyCodable]) async -> ToolResult {
        guard let sid = sessionId else {
            return ToolResult(
                content: "search_conversation unavailable — no session ID",
                isError: true
            )
        }
        let query = input["query"]?.value as? String ?? ""
        let limit = input["limit"]?.value as? Int ?? 10
        guard !query.isEmpty else {
            return ToolResult(content: "query is required", isError: true)
        }
        do {
            let messages = try await MainActor.run {
                try MessageStore.shared.searchMessages(
                    query: query, sessionId: sid, limit: min(limit, 20)
                )
            }
            if messages.isEmpty {
                return ToolResult(
                    content: "No matching messages found for: \(query)",
                    isError: false
                )
            }
            let results = messages.map { m in
                "[\(m.role.rawValue.uppercased())] \(m.content.prefix(500))"
            }.joined(separator: "\n\n---\n\n")
            return ToolResult(content: results, isError: false)
        } catch {
            return ToolResult(
                content: "Search failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    // MARK: - git_status

    private func gitStatus(_ input: [String: AnyCodable]) async -> ToolResult {
        let dir = resolveDirectory(input["path"]?.value as? String)

        let branchResult = await runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)
        let branch = branchResult.success ? branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines) : "unknown"

        let statusResult = await runGit(["status", "--porcelain=v1", "-uall"], in: dir)
        guard statusResult.success else {
            return ToolResult(content: "Not a git repository or git error: \(statusResult.output)", isError: true)
        }

        let lines = statusResult.output.components(separatedBy: "\n").filter { !$0.isEmpty }

        var staged: [[String: String]] = []
        var unstaged: [[String: String]] = []
        var untracked: [[String: String]] = []

        for line in lines {
            guard line.count >= 3 else { continue }
            let indexStatus = line[line.startIndex]
            let worktreeStatus = line[line.index(after: line.startIndex)]
            let filePath = String(line.dropFirst(3))

            if indexStatus == "?" {
                untracked.append(["file": filePath])
            } else {
                if indexStatus != " " {
                    staged.append(["status": describeGitStatus(indexStatus), "file": filePath])
                }
                if worktreeStatus != " " {
                    unstaged.append(["status": describeGitStatus(worktreeStatus), "file": filePath])
                }
            }
        }

        let result: [String: Any] = [
            "branch": branch,
            "clean": lines.isEmpty,
            "staged": staged,
            "unstaged": unstaged,
            "untracked": untracked,
            "summary": "\(staged.count) staged, \(unstaged.count) unstaged, \(untracked.count) untracked"
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
              let jsonStr = String(data: json, encoding: .utf8) else {
            return ToolResult(content: "Failed to serialize git status", isError: true)
        }
        return ToolResult(content: jsonStr, isError: false)
    }

    // MARK: - git_log

    private func gitLog(_ input: [String: AnyCodable]) async -> ToolResult {
        let dir = resolveDirectory(input["path"]?.value as? String)
        let limit = min((input["limit"]?.value as? Int) ?? 20, 100)

        var args = ["log", "--format=%H%n%an%n%aI%n%s", "-n", "\(limit)"]
        if let file = input["file"]?.value as? String {
            args.append("--")
            args.append(file)
        }

        let result = await runGit(args, in: dir)
        guard result.success else {
            return ToolResult(content: "Git log failed: \(result.output)", isError: true)
        }

        let raw = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return ToolResult(content: "[]", isError: false)
        }

        let logLines = raw.components(separatedBy: "\n")
        var commits: [[String: String]] = []
        var i = 0
        while i + 3 < logLines.count {
            commits.append([
                "hash": String(logLines[i].prefix(12)),
                "author": logLines[i + 1],
                "date": logLines[i + 2],
                "message": logLines[i + 3]
            ])
            i += 4
        }

        guard let json = try? JSONSerialization.data(withJSONObject: commits, options: [.prettyPrinted]),
              let jsonStr = String(data: json, encoding: .utf8) else {
            return ToolResult(content: "Failed to serialize git log", isError: true)
        }
        return ToolResult(content: jsonStr, isError: false)
    }

    // MARK: - git_diff

    private func gitDiff(_ input: [String: AnyCodable]) async -> ToolResult {
        let dir = resolveDirectory(input["path"]?.value as? String)
        let staged = (input["staged"]?.value as? Bool) ?? false

        var args = ["diff"]
        if staged {
            args.append("--cached")
        }
        if let ref = input["ref"]?.value as? String {
            args.append(ref)
        }
        args.append("--stat")
        args.append("--patch")
        if let file = input["file"]?.value as? String {
            args.append("--")
            args.append(file)
        }

        let result = await runGit(args, in: dir)
        guard result.success else {
            return ToolResult(content: "Git diff failed: \(result.output)", isError: true)
        }

        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            return ToolResult(content: "No differences found.", isError: false)
        }

        if output.count > maxOutputSize {
            let truncated = String(output.prefix(maxOutputSize))
            return ToolResult(content: truncated + "\n\n[Output truncated at \(maxOutputSize / 1000)KB]", isError: false)
        }
        return ToolResult(content: output, isError: false)
    }

    // MARK: - Git Helpers

    private struct GitResult {
        let output: String
        let success: Bool
    }

    private func runGit(_ arguments: [String], in directory: URL) async -> GitResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = arguments
        proc.currentDirectoryURL = directory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let stdoutAccum = PipeAccumulator()
        let stderrAccum = PipeAccumulator()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                stdoutAccum.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                stderrAccum.append(data)
            }
        }

        do {
            try proc.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return GitResult(output: "Failed to run git: \(error.localizedDescription)", success: false)
        }

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            let timeoutTask = DispatchWorkItem {
                if proc.isRunning { proc.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(30), execute: timeoutTask)
            proc.terminationHandler = { process in
                timeoutTask.cancel()
                continuation.resume(returning: process.terminationStatus)
            }
        }

        let stdout = String(data: stdoutAccum.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrAccum.data, encoding: .utf8) ?? ""

        if exitCode == 0 {
            return GitResult(output: stdout, success: true)
        } else {
            return GitResult(output: stderr.isEmpty ? stdout : stderr, success: false)
        }
    }

    private func resolveDirectory(_ path: String?) -> URL {
        guard let path else { return workingDirectory }
        return URL(fileURLWithPath: resolvePath(path))
    }

    // MARK: - find_unused_code

    private func findUnusedCode(_ input: [String: AnyCodable]) async -> ToolResult {
        let dir = resolveDirectory(input["path"]?.value as? String)
        let kindFilter = (input["kind"]?.value as? String) ?? "all"

        // Gather all Swift files
        let findResult = await runShellCommand(
            "/usr/bin/find", arguments: [dir.path, "-name", "*.swift", "-not", "-path", "*/.*", "-not", "-path", "*/DerivedData/*", "-not", "-path", "*/.build/*"],
            in: dir, timeout: 30
        )
        guard findResult.success else {
            return ToolResult(content: "Failed to scan project: \(findResult.output)", isError: true)
        }

        let files = findResult.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !files.isEmpty else {
            return ToolResult(content: "No Swift files found in \(dir.path)", isError: true)
        }

        // Regex patterns for declarations
        let typePattern = try! NSRegularExpression(
            pattern: #"^(?:\s*(?:public|internal|private|fileprivate|open)\s+)?(?:final\s+)?(?:class|struct|enum|protocol|actor)\s+(\w+)"#,
            options: .anchorsMatchLines
        )
        let funcPattern = try! NSRegularExpression(
            pattern: #"^(?:\s*(?:public|internal|private|fileprivate|open|override)\s+)*func\s+(\w+)"#,
            options: .anchorsMatchLines
        )
        let propPattern = try! NSRegularExpression(
            pattern: #"^\s*(?:public|internal|private|fileprivate|open|lazy|static|class)?\s*(?:var|let)\s+(\w+)"#,
            options: .anchorsMatchLines
        )

        struct Declaration {
            let symbol: String
            let kind: String
            let file: String
            let line: Int
        }

        var declarations: [Declaration] = []
        var allContent = ""

        // Pass 1: collect declarations and concatenate all content for reference searching
        for filePath in files {
            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }
            allContent += content + "\n"
            let lines = content.components(separatedBy: "\n")
            let nsContent = content as NSString
            let range = NSRange(location: 0, length: nsContent.length)

            if kindFilter == "all" || kindFilter == "type" {
                for match in typePattern.matches(in: content, range: range) {
                    let symbol = nsContent.substring(with: match.range(at: 1))
                    let lineNum = content.prefix(match.range.location).components(separatedBy: "\n").count
                    declarations.append(Declaration(symbol: symbol, kind: "type", file: filePath, line: lineNum))
                }
            }

            if kindFilter == "all" || kindFilter == "function" {
                for match in funcPattern.matches(in: content, range: range) {
                    let symbol = nsContent.substring(with: match.range(at: 1))
                    // Skip common overrides and protocol requirements
                    guard !["viewDidLoad", "viewWillAppear", "viewDidAppear", "body", "init",
                             "deinit", "hash", "encode", "decode", "main", "setUp", "tearDown",
                             "setUpWithError", "tearDownWithError"].contains(symbol) else { continue }
                    let lineNum = content.prefix(match.range.location).components(separatedBy: "\n").count
                    declarations.append(Declaration(symbol: symbol, kind: "function", file: filePath, line: lineNum))
                }
            }

            if kindFilter == "all" || kindFilter == "property" {
                for match in propPattern.matches(in: content, range: range) {
                    let symbol = nsContent.substring(with: match.range(at: 1))
                    // Skip common properties
                    guard !["_", "body", "id", "self", "some"].contains(symbol) else { continue }
                    // Check if line is inside a function scope (indentation heuristic: skip deeply indented)
                    let matchLine = lines[min(content.prefix(match.range.location).components(separatedBy: "\n").count - 1, lines.count - 1)]
                    let leadingSpaces = matchLine.prefix(while: { $0 == " " || $0 == "\t" }).count
                    guard leadingSpaces <= 8 else { continue } // Skip local variables
                    let lineNum = content.prefix(match.range.location).components(separatedBy: "\n").count
                    declarations.append(Declaration(symbol: symbol, kind: "property", file: filePath, line: lineNum))
                }
            }
        }

        // Pass 2: count references for each symbol across all content
        let nsAll = allContent as NSString
        var results: [[String: Any]] = []

        for decl in declarations {
            // Count occurrences using word boundary matching
            let refPattern = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: decl.symbol))\\b")
            let count = refPattern?.numberOfMatches(in: allContent, range: NSRange(location: 0, length: nsAll.length)) ?? 0

            // 1 match = only the declaration itself
            if count <= 1 {
                let relativePath = decl.file.hasPrefix(dir.path)
                    ? String(decl.file.dropFirst(dir.path.count + 1))
                    : decl.file
                results.append([
                    "symbol": decl.symbol,
                    "kind": decl.kind,
                    "file": relativePath,
                    "line": decl.line,
                    "confidence": decl.kind == "type" ? "high" : "medium",
                    "references": count
                ])
            }
        }

        // Sort by confidence (high first) then file
        results.sort {
            let c0 = $0["confidence"] as? String ?? ""
            let c1 = $1["confidence"] as? String ?? ""
            if c0 != c1 { return c0 > c1 }
            return ($0["file"] as? String ?? "") < ($1["file"] as? String ?? "")
        }

        // Cap results
        if results.count > 200 {
            results = Array(results.prefix(200))
        }

        guard let json = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]),
              let jsonStr = String(data: json, encoding: .utf8) else {
            return ToolResult(content: "Failed to serialize results", isError: true)
        }

        let summary = "Found \(results.count) potentially unused symbols (\(results.filter { ($0["confidence"] as? String) == "high" }.count) high confidence)"
        return ToolResult(content: "\(summary)\n\n\(jsonStr)", isError: false)
    }

    // MARK: - lint_check

    private func lintCheck(_ input: [String: AnyCodable]) async -> ToolResult {
        let dir = resolveDirectory(input["path"]?.value as? String)
        let fix = (input["fix"]?.value as? Bool) ?? false

        // Check if SwiftLint is available
        let whichResult = await runShellCommand(
            "/usr/bin/which", arguments: ["swiftlint"],
            in: dir, timeout: 5
        )

        if whichResult.success {
            // Use SwiftLint
            let swiftlintPath = whichResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            var args = ["lint", "--reporter", "json", "--quiet"]
            if fix { args = ["lint", "--fix", "--reporter", "json", "--quiet"] }
            args.append("--path")
            args.append(dir.path)

            let lintResult = await runShellCommand(
                swiftlintPath, arguments: args,
                in: dir, timeout: 120
            )

            // SwiftLint returns exit code 0 for warnings-only, non-zero for errors
            let output = lintResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

            // Parse SwiftLint JSON output into our standard format
            if let data = output.data(using: .utf8),
               let rawResults = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var formatted: [[String: Any]] = []
                for item in rawResults {
                    var entry: [String: Any] = [:]
                    entry["file"] = (item["file"] as? String).map { path in
                        path.hasPrefix(dir.path) ? String(path.dropFirst(dir.path.count + 1)) : path
                    } ?? "unknown"
                    entry["line"] = item["line"] ?? 0
                    entry["column"] = item["character"] ?? 0
                    entry["severity"] = (item["severity"] as? String)?.lowercased() ?? "warning"
                    entry["rule"] = item["rule_id"] ?? "unknown"
                    entry["message"] = item["reason"] ?? ""
                    formatted.append(entry)
                }

                guard let json = try? JSONSerialization.data(withJSONObject: formatted, options: [.prettyPrinted]),
                      let jsonStr = String(data: json, encoding: .utf8) else {
                    return ToolResult(content: output, isError: false)
                }

                let errors = formatted.filter { ($0["severity"] as? String) == "error" }.count
                let warnings = formatted.filter { ($0["severity"] as? String) == "warning" }.count
                let summary = "SwiftLint: \(errors) errors, \(warnings) warnings\(fix ? " (auto-fix applied)" : "")"
                return ToolResult(content: "\(summary)\n\n\(jsonStr)", isError: false)
            }

            // Fallback: return raw output if JSON parsing fails
            return ToolResult(content: output.isEmpty ? "No lint issues found." : output, isError: false)
        }

        // Fallback: heuristic lint checks when SwiftLint is not installed
        let findResult = await runShellCommand(
            "/usr/bin/find", arguments: [dir.path, "-name", "*.swift", "-not", "-path", "*/.*", "-not", "-path", "*/DerivedData/*"],
            in: dir, timeout: 30
        )
        guard findResult.success else {
            return ToolResult(content: "Failed to scan project: \(findResult.output)", isError: true)
        }

        let files = findResult.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        var issues: [[String: Any]] = []

        let checks: [(String, NSRegularExpression, String, String)] = [
            ("force_unwrap", try! NSRegularExpression(pattern: #"\w+!"#), "warning", "Force unwrap detected — consider using optional binding"),
            ("force_cast", try! NSRegularExpression(pattern: #"\bas!\s"#), "warning", "Force cast detected — consider using 'as?' with guard"),
            ("long_line", try! NSRegularExpression(pattern: #"^.{200,}$"#, options: .anchorsMatchLines), "warning", "Line exceeds 200 characters"),
            ("todo_fixme", try! NSRegularExpression(pattern: #"//\s*(TODO|FIXME|HACK|XXX)"#), "warning", "TODO/FIXME comment found"),
            ("print_statement", try! NSRegularExpression(pattern: #"^\s*print\("#, options: .anchorsMatchLines), "warning", "Debug print statement found"),
        ]

        for filePath in files.prefix(500) {
            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }
            let nsContent = content as NSString
            let range = NSRange(location: 0, length: nsContent.length)
            let relativePath = filePath.hasPrefix(dir.path) ? String(filePath.dropFirst(dir.path.count + 1)) : filePath

            for (rule, pattern, severity, message) in checks {
                for match in pattern.matches(in: content, range: range) {
                    let lineNum = content.prefix(match.range.location).components(separatedBy: "\n").count
                    issues.append([
                        "file": relativePath,
                        "line": lineNum,
                        "column": 0,
                        "severity": severity,
                        "rule": rule,
                        "message": message
                    ])
                }
            }
        }

        // Cap results
        if issues.count > 500 {
            issues = Array(issues.prefix(500))
        }

        guard let json = try? JSONSerialization.data(withJSONObject: issues, options: [.prettyPrinted]),
              let jsonStr = String(data: json, encoding: .utf8) else {
            return ToolResult(content: "Failed to serialize lint results", isError: true)
        }

        let summary = "Heuristic lint (SwiftLint not found): \(issues.count) issues"
        return ToolResult(content: "\(summary)\n\n\(jsonStr)", isError: false)
    }

    // MARK: - simulator_list

    private func simulatorList(_ input: [String: AnyCodable]) async -> ToolResult {
        let filter = (input["filter"]?.value as? String) ?? "all"

        let result = await runSimctl(["list", "devices", "--json"])
        guard result.success else {
            return ToolResult(content: "Failed to list simulators: \(result.output)", isError: true)
        }

        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else {
            return ToolResult(content: "Failed to parse simulator list", isError: true)
        }

        var simulators: [[String: String]] = []
        for (runtime, deviceList) in devices {
            // Extract runtime name from key (e.g., "com.apple.CoreSimulator.SimRuntime.iOS-17-5" → "iOS 17.5")
            let runtimeName = runtime
                .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                .replacingOccurrences(of: "-", with: ".")
                .replacingOccurrences(of: "..", with: "-")  // Fix double dots from e.g., "iOS-17-5"

            for device in deviceList {
                guard let name = device["name"] as? String,
                      let udid = device["udid"] as? String,
                      let state = device["state"] as? String,
                      let isAvailable = device["isAvailable"] as? Bool,
                      isAvailable else { continue }

                let stateLower = state.lowercased()
                if filter == "booted" && stateLower != "booted" { continue }
                if filter == "shutdown" && stateLower != "shutdown" { continue }

                simulators.append([
                    "name": name,
                    "udid": udid,
                    "state": stateLower,
                    "runtime": runtimeName
                ])
            }
        }

        // Sort: booted first, then by name
        simulators.sort {
            if $0["state"] != $1["state"] {
                return $0["state"] == "booted"
            }
            return ($0["name"] ?? "") < ($1["name"] ?? "")
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: simulators, options: [.prettyPrinted]),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return ToolResult(content: "Failed to serialize simulator list", isError: true)
        }

        let booted = simulators.filter { $0["state"] == "booted" }.count
        let summary = "\(simulators.count) simulators (\(booted) booted)"
        return ToolResult(content: "\(summary)\n\n\(jsonStr)", isError: false)
    }

    // MARK: - simulator_build_run

    private func simulatorBuildRun(_ input: [String: AnyCodable]) async -> ToolResult {
        let dir = resolveDirectory(input["path"]?.value as? String)
        let install = (input["install"]?.value as? Bool) ?? true
        let launch = (input["launch"]?.value as? Bool) ?? true
        let deviceId = input["device_id"]?.value as? String

        // Detect scheme
        let scheme: String
        if let s = input["scheme"]?.value as? String {
            scheme = s
        } else {
            let listResult = await runShellCommand(
                "/usr/bin/xcodebuild",
                arguments: ["-list", "-json"],
                in: dir, timeout: 30
            )
            if listResult.success,
               let data = listResult.output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let project = json["project"] as? [String: Any],
               let schemes = project["schemes"] as? [String],
               let first = schemes.first {
                scheme = first
            } else {
                return ToolResult(content: "Could not auto-detect scheme. Specify one explicitly.", isError: true)
            }
        }

        // Resolve destination simulator
        let destination: String
        if let did = deviceId {
            destination = "platform=iOS Simulator,id=\(did)"
        } else {
            // Find or boot a simulator
            let bootedResult = await runSimctl(["list", "devices", "booted", "--json"])
            var bootedId: String?
            if bootedResult.success,
               let data = bootedResult.output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let devices = json["devices"] as? [String: [[String: Any]]] {
                for (_, deviceList) in devices {
                    if let first = deviceList.first(where: { ($0["state"] as? String) == "Booted" }) {
                        bootedId = first["udid"] as? String
                        break
                    }
                }
            }
            if let bid = bootedId {
                destination = "platform=iOS Simulator,id=\(bid)"
            } else {
                destination = "platform=iOS Simulator,name=iPhone 16"
            }
        }

        // Build
        let buildArgs = [
            "-scheme", scheme,
            "-destination", destination,
            "-derivedDataPath", dir.appendingPathComponent("DerivedData").path,
            "build"
        ]

        let buildResult = await runShellCommand(
            "/usr/bin/xcodebuild", arguments: buildArgs,
            in: dir, timeout: 300
        )

        // Parse build output for errors/warnings
        let nsOutput = buildResult.output as NSString
        let range = NSRange(location: 0, length: nsOutput.length)
        var diagnostics: [[String: Any]] = []

        for match in Self.xcodeDiagnosticPattern.matches(in: buildResult.output, range: range) {
            let file = nsOutput.substring(with: match.range(at: 1))
            let line = nsOutput.substring(with: match.range(at: 2))
            let column = nsOutput.substring(with: match.range(at: 3))
            let severity = nsOutput.substring(with: match.range(at: 4))
            let message = nsOutput.substring(with: match.range(at: 5))

            let relativePath = file.hasPrefix(dir.path) ? String(file.dropFirst(dir.path.count + 1)) : file
            diagnostics.append([
                "file": relativePath,
                "line": Int(line) ?? 0,
                "column": Int(column) ?? 0,
                "severity": severity,
                "message": message
            ])
        }

        guard buildResult.success else {
            let result: [String: Any] = [
                "status": "build_failed",
                "scheme": scheme,
                "diagnostics": diagnostics
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
                  let jsonStr = String(data: json, encoding: .utf8) else {
                return ToolResult(content: "Build failed:\n\(buildResult.output.suffix(2000))", isError: true)
            }
            return ToolResult(content: jsonStr, isError: true)
        }

        var status: [String: Any] = [
            "status": "build_succeeded",
            "scheme": scheme,
            "diagnostics": diagnostics
        ]

        // Install & launch if requested
        if install {
            // Find the .app bundle in DerivedData
            let findApp = await runShellCommand(
                "/usr/bin/find",
                arguments: [
                    dir.appendingPathComponent("DerivedData").path,
                    "-name", "*.app", "-path", "*/Debug-iphonesimulator/*",
                    "-maxdepth", "6"
                ],
                in: dir, timeout: 15
            )

            let appPaths = findApp.output.components(separatedBy: "\n").filter { !$0.isEmpty }
            if let appPath = appPaths.first {
                let targetDevice = deviceId ?? "booted"
                let installResult = await runSimctl(["install", targetDevice, appPath])
                if installResult.success {
                    status["installed"] = true

                    if launch {
                        // Extract bundle ID from Info.plist
                        let plistPath = appPath + "/Info.plist"
                        let bundleResult = await runShellCommand(
                            "/usr/bin/defaults", arguments: ["read", plistPath, "CFBundleIdentifier"],
                            in: dir, timeout: 5
                        )
                        if bundleResult.success {
                            let bundleId = bundleResult.output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                            let launchResult = await runSimctl(["launch", targetDevice, bundleId])
                            status["launched"] = launchResult.success
                            status["bundle_id"] = bundleId
                        }
                    }
                } else {
                    status["installed"] = false
                    status["install_error"] = installResult.output
                }
            } else {
                status["installed"] = false
                status["install_error"] = "Could not find .app bundle in DerivedData"
            }
        }

        guard let json = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]),
              let jsonStr = String(data: json, encoding: .utf8) else {
            return ToolResult(content: "Build succeeded but failed to serialize result", isError: false)
        }
        return ToolResult(content: jsonStr, isError: false)
    }

    // MARK: - simulator_app_manage

    private func simulatorAppManage(_ input: [String: AnyCodable]) async -> ToolResult {
        guard let action = input["action"]?.value as? String else {
            return ToolResult(content: "Missing required parameter: action", isError: true)
        }

        let deviceId = (input["device_id"]?.value as? String) ?? "booted"
        let bundleId = input["bundle_id"]?.value as? String

        switch action {
        case "boot":
            if deviceId == "booted" {
                return ToolResult(content: "Specify device_id to boot a specific simulator", isError: true)
            }
            let result = await runSimctl(["boot", deviceId])
            if result.success {
                // Open Simulator.app to show the UI
                let _ = await runShellCommand("/usr/bin/open", arguments: ["-a", "Simulator"], in: workingDirectory, timeout: 10)
                return ToolResult(content: "Simulator booted: \(deviceId)", isError: false)
            }
            return ToolResult(content: "Failed to boot simulator: \(result.output)", isError: true)

        case "shutdown":
            let result = await runSimctl(["shutdown", deviceId])
            return result.success
                ? ToolResult(content: "Simulator shut down: \(deviceId)", isError: false)
                : ToolResult(content: "Failed to shut down: \(result.output)", isError: true)

        case "launch":
            guard let bid = bundleId else {
                return ToolResult(content: "Missing required parameter: bundle_id", isError: true)
            }
            let result = await runSimctl(["launch", deviceId, bid])
            return result.success
                ? ToolResult(content: "Launched \(bid) on \(deviceId)", isError: false)
                : ToolResult(content: "Failed to launch: \(result.output)", isError: true)

        case "terminate":
            guard let bid = bundleId else {
                return ToolResult(content: "Missing required parameter: bundle_id", isError: true)
            }
            let result = await runSimctl(["terminate", deviceId, bid])
            return result.success
                ? ToolResult(content: "Terminated \(bid) on \(deviceId)", isError: false)
                : ToolResult(content: "Failed to terminate: \(result.output)", isError: true)

        case "uninstall":
            guard let bid = bundleId else {
                return ToolResult(content: "Missing required parameter: bundle_id", isError: true)
            }
            let result = await runSimctl(["uninstall", deviceId, bid])
            return result.success
                ? ToolResult(content: "Uninstalled \(bid) from \(deviceId)", isError: false)
                : ToolResult(content: "Failed to uninstall: \(result.output)", isError: true)

        case "list_apps":
            let result = await runSimctl(["listapps", deviceId])
            guard result.success else {
                return ToolResult(content: "Failed to list apps: \(result.output)", isError: true)
            }
            // Parse the plist-style output to extract bundle IDs
            if let data = result.output.data(using: .utf8),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] {
                var apps: [[String: String]] = []
                for (bundleId, info) in plist {
                    apps.append([
                        "bundle_id": bundleId,
                        "name": (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleId,
                        "version": (info["CFBundleShortVersionString"] as? String) ?? "unknown"
                    ])
                }
                apps.sort { ($0["name"] ?? "") < ($1["name"] ?? "") }
                guard let json = try? JSONSerialization.data(withJSONObject: apps, options: [.prettyPrinted]),
                      let jsonStr = String(data: json, encoding: .utf8) else {
                    return ToolResult(content: result.output, isError: false)
                }
                return ToolResult(content: "\(apps.count) apps installed\n\n\(jsonStr)", isError: false)
            }
            // Fallback: return raw output
            return ToolResult(content: result.output, isError: false)

        default:
            return ToolResult(content: "Unknown action: \(action). Use: launch, terminate, uninstall, list_apps, boot, shutdown", isError: true)
        }
    }

    // MARK: - simulator_screenshot

    private func simulatorScreenshot(_ input: [String: AnyCodable]) async -> ToolResult {
        let deviceId = (input["device_id"]?.value as? String) ?? "booted"

        let outputPath: String
        if let custom = input["output_path"]?.value as? String {
            outputPath = resolvePath(custom)
        } else {
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            outputPath = "/tmp/simulator-screenshot-\(timestamp).png"
        }

        let result = await runSimctl(["io", deviceId, "screenshot", outputPath])
        guard result.success else {
            return ToolResult(content: "Failed to capture screenshot: \(result.output)", isError: true)
        }

        // Verify file exists
        guard FileManager.default.fileExists(atPath: outputPath) else {
            return ToolResult(content: "Screenshot command succeeded but file not found at \(outputPath)", isError: true)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath)
        let size = (attrs?[.size] as? Int) ?? 0

        let resultObj: [String: Any] = [
            "path": outputPath,
            "size_bytes": size,
            "device": deviceId
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: resultObj, options: [.prettyPrinted]),
              let jsonStr = String(data: json, encoding: .utf8) else {
            return ToolResult(content: "Screenshot saved to \(outputPath)", isError: false)
        }
        return ToolResult(content: jsonStr, isError: false)
    }

    // MARK: - Simctl Helper

    private struct ShellResult: Sendable {
        let output: String
        let success: Bool
    }

    private func runSimctl(_ arguments: [String]) async -> ShellResult {
        await runShellCommand("/usr/bin/xcrun", arguments: ["simctl"] + arguments, in: workingDirectory, timeout: 60)
    }

    private func runShellCommand(_ executable: String, arguments: [String], in directory: URL, timeout: Int) async -> ShellResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = directory

        // Include homebrew paths for tools like swiftlint
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(home)/.local/bin:\(home)/.cortana/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        env["HOME"] = home
        proc.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let stdoutAccum = PipeAccumulator()
        let stderrAccum = PipeAccumulator()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                stdoutAccum.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                stderrAccum.append(data)
            }
        }

        do {
            try proc.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return ShellResult(output: "Failed to run \(executable): \(error.localizedDescription)", success: false)
        }

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            let timeoutTask = DispatchWorkItem {
                if proc.isRunning { proc.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout), execute: timeoutTask)
            proc.terminationHandler = { process in
                timeoutTask.cancel()
                continuation.resume(returning: process.terminationStatus)
            }
        }

        let stdout = String(data: stdoutAccum.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrAccum.data, encoding: .utf8) ?? ""

        if exitCode == 0 {
            return ShellResult(output: stdout, success: true)
        } else {
            return ShellResult(output: stderr.isEmpty ? stdout : stderr, success: false)
        }
    }

    private func describeGitStatus(_ char: Character) -> String {
        switch char {
        case "M": return "modified"
        case "A": return "added"
        case "D": return "deleted"
        case "R": return "renamed"
        case "C": return "copied"
        case "U": return "unmerged"
        case "T": return "typechange"
        default: return String(char)
        }
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
