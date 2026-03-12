import Foundation

/// Background git diff execution and structured parsing for diff review.
/// Runs git operations off-main via actor isolation — never blocks UI.
actor DiffReviewStore {
    static let shared = DiffReviewStore()

    // MARK: - Models

    struct DiffResult: Sendable {
        let sessionId: String
        let files: [FileDiff]
        let totalAdditions: Int
        let totalDeletions: Int
        let generatedAt: Date
    }

    struct FileDiff: Identifiable, Sendable {
        let id: String  // file path
        let path: String
        let status: FileStatus
        let additions: Int
        let deletions: Int
        let hunks: [DiffHunk]
    }

    enum FileStatus: String, Sendable {
        case added = "A"
        case modified = "M"
        case deleted = "D"
        case renamed = "R"
    }

    struct DiffHunk: Identifiable, Sendable {
        let id: Int
        let header: String
        let lines: [DiffLine]
    }

    struct DiffLine: Identifiable, Sendable {
        let id: Int
        let type: LineType
        let content: String
        let oldLineNumber: Int?
        let newLineNumber: Int?
    }

    enum LineType: Sendable {
        case context, addition, deletion
    }

    // MARK: - Cache

    private var cache: [String: DiffResult] = [:]

    // MARK: - Public API

    /// Generate a diff for an agent session using its working directory.
    func generateDiff(for session: AgentSession) async -> DiffResult? {
        return await generateDiff(inDirectory: session.workingDirectory, sessionId: session.id)
    }

    /// Generate a diff in a specific directory.
    func generateDiff(inDirectory dir: String, sessionId: String) async -> DiffResult? {
        // Return cached if fresh (< 30 seconds)
        if let cached = cache[sessionId],
           Date().timeIntervalSince(cached.generatedAt) < 30 {
            return cached
        }

        // Verify directory exists
        guard FileManager.default.fileExists(atPath: dir) else { return nil }

        // Try diff strategies in order
        var rawDiff: String?
        rawDiff = await runGitDiff(in: dir, arguments: ["diff", "HEAD~1"])
        if rawDiff == nil {
            rawDiff = await runGitDiff(in: dir, arguments: ["diff", "--cached"])
        }
        if rawDiff == nil {
            rawDiff = await runGitDiff(in: dir, arguments: ["diff"])
        }

        guard let output = rawDiff, !output.isEmpty else { return nil }

        let files = parseDiff(output)
        let totalAdd = files.reduce(0) { $0 + $1.additions }
        let totalDel = files.reduce(0) { $0 + $1.deletions }

        let result = DiffResult(
            sessionId: sessionId,
            files: files,
            totalAdditions: totalAdd,
            totalDeletions: totalDel,
            generatedAt: Date()
        )

        cache[sessionId] = result
        return result
    }

    /// Clear cached diff for a session.
    func clearCache(for sessionId: String) {
        cache.removeValue(forKey: sessionId)
    }

    // MARK: - Git Process Execution

    private func runGitDiff(in dir: String, arguments: [String]) async -> String? {
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: dir)

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            // Timeout: terminate after 10 seconds
            let timeoutItem = DispatchWorkItem { [weak process] in
                if let p = process, p.isRunning {
                    p.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutItem)

            do {
                try process.run()
                process.waitUntilExit()
                timeoutItem.cancel()

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)
                continuation.resume(returning: output)
            } catch {
                timeoutItem.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Diff Parser

    private func parseDiff(_ raw: String) -> [FileDiff] {
        let lines = raw.components(separatedBy: "\n")
        var files: [FileDiff] = []

        var currentPath: String?
        var currentStatus: FileStatus = .modified
        var currentHunks: [DiffHunk] = []
        var currentHunkLines: [DiffLine] = []
        var currentHunkHeader: String = ""
        var hunkId = 0
        var lineId = 0
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            if !currentHunkLines.isEmpty {
                currentHunks.append(DiffHunk(
                    id: hunkId,
                    header: currentHunkHeader,
                    lines: currentHunkLines
                ))
                hunkId += 1
                currentHunkLines = []
            }
        }

        func flushFile() {
            flushHunk()
            if let path = currentPath {
                let additions = currentHunks.flatMap(\.lines).filter { $0.type == .addition }.count
                let deletions = currentHunks.flatMap(\.lines).filter { $0.type == .deletion }.count
                files.append(FileDiff(
                    id: path,
                    path: path,
                    status: currentStatus,
                    additions: additions,
                    deletions: deletions,
                    hunks: currentHunks
                ))
                currentHunks = []
                currentPath = nil
                currentStatus = .modified
            }
        }

        for line in lines {
            // New file diff header
            if line.hasPrefix("diff --git ") {
                flushFile()
                // Extract path from "diff --git a/path b/path"
                let parts = line.split(separator: " ")
                if parts.count >= 4 {
                    let bPath = String(parts.last ?? "")
                    currentPath = bPath.hasPrefix("b/") ? String(bPath.dropFirst(2)) : bPath
                }
                currentStatus = .modified
                continue
            }

            // Status markers
            if line.hasPrefix("new file mode") {
                currentStatus = .added
                continue
            }
            if line.hasPrefix("deleted file mode") {
                currentStatus = .deleted
                continue
            }
            if line.hasPrefix("rename from") || line.hasPrefix("rename to") {
                currentStatus = .renamed
                continue
            }

            // Skip file headers
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("index ") {
                continue
            }

            // Hunk header
            if line.hasPrefix("@@") {
                flushHunk()
                currentHunkHeader = line
                // Parse "@@ -10,5 +10,8 @@" for line numbers
                let scanner = Scanner(string: line)
                _ = scanner.scanString("@@")
                _ = scanner.scanString("-")
                if let old = scanner.scanInt() { oldLine = old } else { oldLine = 1 }
                _ = scanner.scanUpToString("+")
                _ = scanner.scanString("+")
                if let new = scanner.scanInt() { newLine = new } else { newLine = 1 }
                continue
            }

            // Diff content lines (only inside a hunk)
            guard currentPath != nil else { continue }

            if line.hasPrefix("+") {
                currentHunkLines.append(DiffLine(
                    id: lineId,
                    type: .addition,
                    content: String(line.dropFirst()),
                    oldLineNumber: nil,
                    newLineNumber: newLine
                ))
                lineId += 1
                newLine += 1
            } else if line.hasPrefix("-") {
                currentHunkLines.append(DiffLine(
                    id: lineId,
                    type: .deletion,
                    content: String(line.dropFirst()),
                    oldLineNumber: oldLine,
                    newLineNumber: nil
                ))
                lineId += 1
                oldLine += 1
            } else if line.hasPrefix(" ") {
                currentHunkLines.append(DiffLine(
                    id: lineId,
                    type: .context,
                    content: String(line.dropFirst()),
                    oldLineNumber: oldLine,
                    newLineNumber: newLine
                ))
                lineId += 1
                oldLine += 1
                newLine += 1
            }
        }

        // Flush last file
        flushFile()

        return files
    }
}
