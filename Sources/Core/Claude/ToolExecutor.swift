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

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    func execute(name: String, input: [String: AnyCodable]) async -> ToolResult {
        switch name {
        case "read_file": return readFile(input)
        case "write_file": return await writeFile(input)
        case "edit_file": return await editFile(input)
        case "bash": return await bash(input)
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
            canvasLog("[ToolGuard] BLOCKED: \(assessment.reason) — command: \(command.prefix(100))")
            return ToolResult(
                content: "[Security Gate] Operation blocked: \(assessment.reason). Command requires human approval.",
                isError: true
            )
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

        // Async wait with timeout — avoids blocking MainActor
        let exitCode: Int32 = await withCheckedContinuation { continuation in
            // Timeout enforcement
            let timeoutTask = DispatchWorkItem {
                if proc.isRunning { proc.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSecs), execute: timeoutTask)

            proc.terminationHandler = { process in
                timeoutTask.cancel()
                continuation.resume(returning: process.terminationStatus)
            }
        }

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

        var output = "Canvas Checkpoints:\n"
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
            output += "\n## Canvas Background Jobs\n"
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

        let command: String
        if target == "simulator" {
            if let deviceId {
                // Sanitize: UDIDs are hex + hyphens only
                let safeId = deviceId.filter { $0.isHexDigit || $0 == "-" }
                command = "xcrun simctl io '\(safeId)' screenshot '\(outputPath)' 2>&1"
            } else {
                command = "xcrun simctl io booted screenshot '\(outputPath)' 2>&1"
            }
        } else {
            // Full Mac screen capture
            command = "screencapture -x '\(outputPath)' 2>&1"
        }

        let result = await bash(["command": AnyCodable(command)])
        if result.isError {
            return ToolResult(content: "Failed to capture screenshot: \(result.content)", isError: true)
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            return ToolResult(content: "Screenshot command ran but file not found at \(outputPath). Output: \(result.content)", isError: true)
        }

        let targetLabel = target == "simulator" ? "iOS Simulator" : "Mac screen"
        return ToolResult(
            content: "Screenshot captured (\(targetLabel)).\nFile: \(outputPath)",
            isError: false
        )
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
