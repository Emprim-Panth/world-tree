import Foundation

// MARK: - PencilMCPError

enum PencilMCPError: Error, LocalizedError {
    case binaryNotFound
    case processStartFailed(String)
    case serverUnreachable
    case toolCallFailed(String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Pencil MCP binary not found. Install Pencil.app or the VS Code extension."
        case .processStartFailed(let msg):
            return "Failed to start Pencil MCP server: \(msg)"
        case .serverUnreachable:
            return "Pencil MCP server is not responding"
        case .toolCallFailed(let msg):
            return "Tool call failed: \(msg)"
        case .parseError:
            return "Failed to parse Pencil response"
        }
    }
}

// MARK: - PencilMCPClient

/// Stdio MCP client for Pencil's local server.
///
/// Spawns the Pencil MCP binary as a subprocess and communicates via
/// stdin/stdout pipes using newline-delimited JSON-RPC 2.0.
///
/// World Tree is a **read-only consumer** of Pencil's canvas.
/// `batchDesign` and `setVariables` are internal and never exposed to UI —
/// calling them risks corrupting canvas state during live Claude Code sessions.
///
/// Binary discovery order:
///   1. UserDefaults override (pencil.binary.path)
///   2. /Applications/Pencil.app bundle
///   3. ~/.vscode/extensions/highagency.pencildev-*/out/
///   4. ~/.cursor/extensions/highagency.pencildev-*/out/
actor PencilMCPClient {

    // MARK: - Static Keys

    static let binaryPathOverrideKey = "pencil.binary.path"

    // MARK: - Process State

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutReadTask: Task<Void, Never>?
    private var isInitialized = false

    // MARK: - Request Routing

    private var requestIDCounter = 0
    private var pendingRequests: [Int: CheckedContinuation<Any, Error>] = [:]

    // MARK: - Init / Deinit

    init() {}

    // MARK: - Binary Discovery

    /// Finds the Pencil MCP server binary on this machine.
    /// Returns nil if Pencil is not installed anywhere we know to look.
    static func discoverBinaryPath() -> String? {
        // 1. User override
        if let override = UserDefaults.standard.string(forKey: binaryPathOverrideKey),
           !override.isEmpty,
           FileManager.default.fileExists(atPath: override) {
            return override
        }

        let fm = FileManager.default
        let home = NSHomeDirectory()
        let arch = ProcessInfo.processInfo.machineHardwareClass

        // Binary names to try (arm64 first on Apple Silicon, x86 fallback)
        let binaryNames: [String]
        if arch == "arm64" {
            binaryNames = ["mcp-server-darwin-arm64", "mcp-server-darwin-x64", "mcp-server"]
        } else {
            binaryNames = ["mcp-server-darwin-x64", "mcp-server-darwin-arm64", "mcp-server"]
        }

        // 2. Standalone Pencil.app
        let appPaths = [
            "/Applications/Pencil.app",
            "\(home)/Applications/Pencil.app"
        ]
        for appPath in appPaths {
            for name in binaryNames {
                let candidates = [
                    "\(appPath)/Contents/MacOS/\(name)",
                    "\(appPath)/Contents/Resources/\(name)",
                    "\(appPath)/Contents/Resources/app/\(name)",
                ]
                for c in candidates where fm.fileExists(atPath: c) { return c }
            }
        }

        // 3. VS Code extension
        let vscodeExtDir = "\(home)/.vscode/extensions"
        if let exts = try? fm.contentsOfDirectory(atPath: vscodeExtDir) {
            for ext in exts.sorted().reversed() where ext.hasPrefix("highagency.pencildev") {
                for name in binaryNames {
                    let path = "\(vscodeExtDir)/\(ext)/out/\(name)"
                    if fm.fileExists(atPath: path) { return path }
                }
            }
        }

        // 4. Cursor extension
        let cursorExtDir = "\(home)/.cursor/extensions"
        if let exts = try? fm.contentsOfDirectory(atPath: cursorExtDir) {
            for ext in exts.sorted().reversed() where ext.hasPrefix("highagency.pencildev") {
                for name in binaryNames {
                    let path = "\(cursorExtDir)/\(ext)/out/\(name)"
                    if fm.fileExists(atPath: path) { return path }
                }
            }
        }

        // 5. Windsurf extension
        let windsurfExtDir = "\(home)/.windsurf/extensions"
        if let exts = try? fm.contentsOfDirectory(atPath: windsurfExtDir) {
            for ext in exts.sorted().reversed() where ext.hasPrefix("highagency.pencildev") {
                for name in binaryNames {
                    let path = "\(windsurfExtDir)/\(ext)/out/\(name)"
                    if fm.fileExists(atPath: path) { return path }
                }
            }
        }

        return nil
    }

    // MARK: - Health

    /// Returns true if the Pencil binary exists and responds to initialize.
    /// Guaranteed to return within ~3 seconds.
    func ping() async -> Bool {
        do {
            try ensureProcessRunning()
            if !isInitialized {
                try await performInitialize()
            }
            return true
        } catch {
            terminateProcess()
            return false
        }
    }

    // MARK: - Pencil MCP Tools (Read-Only)

    /// Get specific nodes by ID from the canvas
    func batchGet(nodeIds: [String]) async throws -> [PencilNode] {
        let result = try await callTool("batch_get", arguments: ["nodeIds": nodeIds])
        return try decode([PencilNode].self, from: result)
    }

    /// Get a PNG screenshot of the current canvas state
    func getScreenshot() async throws -> Data {
        let result = try await callTool("get_screenshot", arguments: [:])
        guard let base64 = result as? String,
              let data = Data(base64Encoded: base64) else {
            throw PencilMCPError.parseError
        }
        return data
    }

    /// Snapshot the current canvas layout — frames, positions, structure
    func snapshotLayout() async throws -> PencilLayout {
        let result = try await callTool("snapshot_layout", arguments: [:])
        return try decode(PencilLayout.self, from: result)
    }

    /// Get the current editor state — open file, selection, zoom
    func getEditorState() async throws -> PencilEditorState {
        let result = try await callTool("get_editor_state", arguments: [:])
        return try decode(PencilEditorState.self, from: result)
    }

    /// Get design variables / tokens
    func getVariables() async throws -> [PencilVariable] {
        let result = try await callTool("get_variables", arguments: [:])
        return try decode([PencilVariable].self, from: result)
    }

    // MARK: - Write Tools (Internal — Read-Only Consumer Policy)

    /// Batch design operations on the canvas.
    /// Intentionally not exposed to UI — read-only consumer policy.
    internal func batchDesign(ops: [[String: Any]]) async throws -> PencilBatchResult {
        let result = try await callTool("batch_design", arguments: ["operations": ops])
        return try decode(PencilBatchResult.self, from: result)
    }

    /// Set design variables / tokens.
    /// Intentionally not exposed to UI — read-only consumer policy.
    internal func setVariables(_ vars: [PencilVariable]) async throws {
        let encoded = vars.map { ["name": $0.name, "value": $0.value] }
        _ = try await callTool("set_variables", arguments: ["variables": encoded])
    }

    // MARK: - Process Management

    private func ensureProcessRunning() throws {
        if let p = process, p.isRunning { return }

        guard let binaryPath = Self.discoverBinaryPath() else {
            throw PencilMCPError.binaryNotFound
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.arguments = []

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        p.terminationHandler = { [weak self] _ in
            Task { [weak self] in await self?.handleProcessTermination() }
        }

        do {
            try p.launch()
        } catch {
            throw PencilMCPError.processStartFailed(error.localizedDescription)
        }

        process = p
        stdinPipe = stdin
        isInitialized = false

        // Start reading stdout in background
        let fileHandle = stdout.fileHandleForReading
        stdoutReadTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await line in fileHandle.bytes.lines {
                    guard !line.isEmpty else { continue }
                    guard let data = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continue
                    }
                    await self.handleMessage(json)
                }
            } catch {
                // Process ended or pipe closed — terminate cleanly
                await self.handleProcessTermination()
            }
        }
    }

    private func terminateProcess() {
        stdoutReadTask?.cancel()
        stdoutReadTask = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        isInitialized = false

        // Fail all pending requests
        let pending = pendingRequests
        pendingRequests = [:]
        for (_, continuation) in pending {
            continuation.resume(throwing: PencilMCPError.serverUnreachable)
        }
    }

    private func handleProcessTermination() {
        process = nil
        stdinPipe = nil
        isInitialized = false
        stdoutReadTask?.cancel()
        stdoutReadTask = nil

        let pending = pendingRequests
        pendingRequests = [:]
        for (_, continuation) in pending {
            continuation.resume(throwing: PencilMCPError.serverUnreachable)
        }
    }

    // MARK: - MCP Protocol

    private func performInitialize() async throws {
        let params: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "WorldTree", "version": "1.1.0"]
        ]
        _ = try await withMCPTimeout(3) {
            try await self.sendRequest(method: "initialize", params: params)
        }
        isInitialized = true
    }

    private func callTool(_ name: String, arguments: [String: Any]) async throws -> Any {
        try ensureProcessRunning()
        if !isInitialized { try await performInitialize() }
        return try await withMCPTimeout(15) {
            try await self.sendRequest(
                method: "tools/call",
                params: ["name": name, "arguments": arguments]
            )
        }
    }

    private func sendRequest(method: String, params: [String: Any]) async throws -> Any {
        let id = nextID()
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": id
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let line = String(data: data, encoding: .utf8) else {
            throw PencilMCPError.parseError
        }

        guard let stdin = stdinPipe else {
            throw PencilMCPError.serverUnreachable
        }

        // Write newline-terminated JSON to stdin
        let payload = (line + "\n").data(using: .utf8)!
        stdin.fileHandleForWriting.write(payload)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
        }
    }

    private func handleMessage(_ json: [String: Any]) {
        // MCP responses have an "id" field — notifications do not
        guard let id = json["id"] as? Int,
              let continuation = pendingRequests.removeValue(forKey: id) else {
            return  // Notification or unknown message — ignore
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            continuation.resume(throwing: PencilMCPError.toolCallFailed(message))
            return
        }

        guard let result = json["result"] else {
            continuation.resume(throwing: PencilMCPError.parseError)
            return
        }

        // MCP tools/call wraps result in content[0].text as a JSON string
        if let resultDict = result as? [String: Any],
           let content = resultDict["content"] as? [[String: Any]],
           let firstContent = content.first,
           let text = firstContent["text"] as? String {
            if let jsonData = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) {
                continuation.resume(returning: parsed)
            } else {
                continuation.resume(returning: text)
            }
            return
        }

        continuation.resume(returning: result)
    }

    private func nextID() -> Int {
        requestIDCounter += 1
        return requestIDCounter
    }

    // MARK: - Timeout Helper

    private func withMCPTimeout<T: Sendable>(
        _ seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PencilMCPError.serverUnreachable
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Decode Helpers

    private func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        let data: Data
        if let dict = value as? [String: Any] {
            data = try JSONSerialization.data(withJSONObject: dict)
        } else if let array = value as? [[String: Any]] {
            data = try JSONSerialization.data(withJSONObject: array)
        } else if let string = value as? String, let stringData = string.data(using: .utf8) {
            data = stringData
        } else {
            throw PencilMCPError.parseError
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - ProcessInfo Extension

private extension ProcessInfo {
    var machineHardwareClass: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafeBytes(of: &sysinfo.machine) { ptr in
            let bytes = ptr.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
    }
}
