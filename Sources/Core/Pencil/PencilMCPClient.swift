import Foundation

// MARK: - PencilMCPError

enum PencilMCPError: Error, LocalizedError {
    case serverUnreachable
    case toolCallFailed(String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .serverUnreachable:    return "Pencil MCP server is not reachable"
        case .toolCallFailed(let msg): return "Tool call failed: \(msg)"
        case .parseError:           return "Failed to parse Pencil response"
        }
    }
}

// MARK: - PencilMCPClient

/// HTTP MCP client for Pencil's local server.
///
/// World Tree is a **read-only consumer** of Pencil's canvas.
/// `batchDesign` and `setVariables` are internal and never exposed to UI —
/// calling them risks corrupting canvas state during live Claude Code sessions.
///
/// Follows the GatewayClient actor pattern: URLSession, 15s/60s timeouts,
/// no @MainActor on the actor itself.
actor PencilMCPClient {
    private let session: URLSession
    private let pingSession: URLSession   // Dedicated 2s timeout for ping
    private var requestIDCounter: Int = 0
    private var serverURL: URL

    static let userDefaultsURLKey = "pencil.mcp.url"
    static let defaultURL = "http://localhost:4100"

    init(urlOverride: String? = nil) {
        let urlString = urlOverride
            ?? UserDefaults.standard.string(forKey: Self.userDefaultsURLKey)
            ?? Self.defaultURL
        self.serverURL = URL(string: urlString) ?? URL(string: Self.defaultURL)!

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)

        let pingConfig = URLSessionConfiguration.default
        pingConfig.timeoutIntervalForRequest = 2
        pingConfig.timeoutIntervalForResource = 5
        self.pingSession = URLSession(configuration: pingConfig)
    }

    func updateURL(_ urlString: String) {
        if let url = URL(string: urlString) {
            serverURL = url
        }
    }

    // MARK: - Health

    /// Returns true if the Pencil MCP server is reachable, false otherwise.
    /// Guaranteed to return within ~2 seconds regardless of server state.
    func ping() async -> Bool {
        let url = serverURL.appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await pingSession.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            // Fall through — try initialize handshake instead
        }
        // Some MCP servers don't have /health — try initialize
        do {
            _ = try await callRaw(method: "initialize", params: [:], usePingSession: true)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Pencil MCP Tools (Read-Only)

    /// Get specific nodes by ID from the canvas
    func batchGet(nodeIds: [String]) async throws -> [PencilNode] {
        let params: [String: Any] = ["nodeIds": nodeIds]
        let result = try await callTool("batch_get", arguments: params)
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
    /// Calling this risks corrupting canvas state during live Claude Code sessions.
    internal func batchDesign(ops: [[String: Any]]) async throws -> PencilBatchResult {
        let params: [String: Any] = ["operations": ops]
        let result = try await callTool("batch_design", arguments: params)
        return try decode(PencilBatchResult.self, from: result)
    }

    /// Set design variables / tokens.
    /// Intentionally not exposed to UI — read-only consumer policy.
    internal func setVariables(_ vars: [PencilVariable]) async throws {
        let encoded = vars.map { ["name": $0.name, "value": $0.value] }
        let params: [String: Any] = ["variables": encoded]
        _ = try await callTool("set_variables", arguments: params)
    }

    // MARK: - JSON-RPC Core

    private func nextID() -> Int {
        requestIDCounter += 1
        return requestIDCounter
    }

    private func callTool(_ name: String, arguments: [String: Any]) async throws -> Any {
        return try await callRaw(
            method: "tools/call",
            params: ["name": name, "arguments": arguments],
            usePingSession: false
        )
    }

    private func callRaw(method: String, params: [String: Any], usePingSession: Bool) async throws -> Any {
        let id = nextID()
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": id
        ]

        let url = serverURL.appendingPathComponent("mcp")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let chosenSession = usePingSession ? pingSession : session
        let (data, response) = try await chosenSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PencilMCPError.serverUnreachable
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PencilMCPError.parseError
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw PencilMCPError.toolCallFailed(message)
        }

        guard let result = json["result"] else {
            throw PencilMCPError.parseError
        }

        // MCP tools/call returns result.content[0].text as JSON string
        if let resultDict = result as? [String: Any],
           let content = resultDict["content"] as? [[String: Any]],
           let firstContent = content.first,
           let text = firstContent["text"] as? String {
            // Try to parse as JSON, fall back to raw string
            if let jsonData = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) {
                return parsed
            }
            return text
        }

        return result
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
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw PencilMCPError.parseError
        }
    }
}
