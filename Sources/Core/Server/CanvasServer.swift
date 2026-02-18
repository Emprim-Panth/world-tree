import Foundation
import Network

// MARK: - CanvasServer

/// HTTP/SSE server that exposes Canvas sessions to external clients.
///
/// Telegram bot and MacBook Canvas (remote mode) POST messages and receive
/// Claude tokens as Server-Sent Events. All endpoints except `/health`
/// require the `x-canvas-token` header.
///
/// Port 5865. Token stored in UserDefaults under `cortana.serverToken`.
@MainActor
final class CanvasServer: ObservableObject {
    static let shared = CanvasServer()

    static let port: UInt16 = 5865
    static let tokenKey = "cortana.serverToken"
    static let enabledKey = "cortana.serverEnabled"

    @Published private(set) var isRunning = false
    @Published private(set) var requestCount = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var ngrokPublicURL: String?

    private var listener: NWListener?
    private let networkQueue = DispatchQueue(label: "cortana.canvas-server", qos: .userInitiated)

    var configuredToken: String {
        UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
    }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        guard !configuredToken.isEmpty else {
            lastError = "No server token — set it in Settings → Server"
            canvasLog("[CanvasServer] Cannot start: no token configured")
            return
        }

        do {
            let listener = try NWListener(
                using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                // NWListener delivers on networkQueue; hop to MainActor for start()
                Task { @MainActor [weak self] in self?.beginConnection(connection) }
            }

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.startedAt = Date()
                        self.lastError = nil
                        self.writeStateFile(ngrokURL: nil)
                        canvasLog("[CanvasServer] Ready on port \(Self.port)")
                        // Discover ngrok tunnel URL (if running) after a short delay
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                            await self?.discoverAndWriteNgrokURL()
                        }
                    case .failed(let error):
                        self.isRunning = false
                        self.lastError = error.localizedDescription
                        canvasLog("[CanvasServer] Failed: \(error)")
                    case .cancelled:
                        self.isRunning = false
                        canvasLog("[CanvasServer] Stopped")
                    default:
                        break
                    }
                }
            }

            listener.start(queue: networkQueue)
        } catch {
            lastError = error.localizedDescription
            canvasLog("[CanvasServer] Listener init failed: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        ngrokPublicURL = nil
        removeStateFile()
    }

    // MARK: - State File (for external clients like Telegram bot)

    /// Writes ~/.cortana/state/canvas-server.json so Python scripts can discover the token and URLs.
    /// ngrokURL is the public tunnel URL — nil until discovered after startup.
    private func writeStateFile(ngrokURL: String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let stateDir = URL(fileURLWithPath: "\(home)/.cortana/state")
        let stateFile = stateDir.appendingPathComponent("canvas-server.json")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        var state: [String: Any] = [
            "url": "http://localhost:\(Self.port)",
            "port": Self.port,
            "token": configuredToken,
            "started_at": ISO8601DateFormatter().string(from: Date())
        ]
        if let ngrok = ngrokURL {
            state["ngrok_url"] = ngrok
            canvasLog("[CanvasServer] ngrok URL: \(ngrok)")
        }
        if let data = try? JSONSerialization.data(withJSONObject: state, options: .prettyPrinted) {
            try? data.write(to: stateFile)
        }
    }

    private func removeStateFile() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let stateFile = URL(fileURLWithPath: "\(home)/.cortana/state/canvas-server.json")
        try? FileManager.default.removeItem(at: stateFile)
    }

    // MARK: - ngrok URL Discovery

    /// Polls the ngrok local API to find the active tunnel for our port.
    /// Writes the public URL to canvas-server.json when found.
    private func discoverAndWriteNgrokURL() async {
        guard let url = URL(string: "http://localhost:4040/api/tunnels") else { return }

        // Retry a few times — ngrok may take a moment to establish the tunnel
        for attempt in 1...5 {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let ngrokURL = parseNgrokURL(from: data) {
                    writeStateFile(ngrokURL: ngrokURL)
                    self.ngrokPublicURL = ngrokURL
                    return
                }
            } catch {
                // ngrok not running yet
            }
            if attempt < 5 {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s between retries
            }
        }
        canvasLog("[CanvasServer] No ngrok tunnel detected — remote access unavailable")
    }

    private func parseNgrokURL(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tunnels = json["tunnels"] as? [[String: Any]] else { return nil }

        // Find the https tunnel forwarding to our port
        for tunnel in tunnels {
            let proto = tunnel["proto"] as? String ?? ""
            let publicURL = tunnel["public_url"] as? String ?? ""
            let config = tunnel["config"] as? [String: Any] ?? [:]
            let addr = config["addr"] as? String ?? ""

            if proto == "https" && addr.contains("\(Self.port)") {
                return publicURL
            }
            // Also accept http tunnel if no https
            if proto == "http" && addr.contains("\(Self.port)") {
                return publicURL
            }
        }

        // Fallback: return first https tunnel
        return tunnels.first { $0["proto"] as? String == "https" }?["public_url"] as? String
    }

    // MARK: - Connection Entry (MainActor)

    private func beginConnection(_ connection: NWConnection) {
        // Start the connection delivering callbacks on networkQueue
        connection.start(queue: networkQueue)
        // Hand off to nonisolated receive loop
        Self.receiveData(from: connection, token: configuredToken, accumulated: Data())
    }

    // MARK: - Receive Loop (nonisolated)

    /// Accumulates raw TCP bytes until a complete HTTP/1.1 request arrives, then dispatches.
    /// Runs on NWConnection's callback queue — no MainActor access here.
    private nonisolated static func receiveData(from connection: NWConnection, token: String, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, isComplete, error in
            if let error {
                canvasLog("[CanvasServer] Receive error: \(error)")
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let chunk { buffer.append(chunk) }

            // Wait for the full HTTP header block (\r\n\r\n terminator)
            let terminator = Data("\r\n\r\n".utf8)
            guard let headerEnd = buffer.range(of: terminator) else {
                if isComplete { connection.cancel() }
                else { receiveData(from: connection, token: token, accumulated: buffer) }
                return
            }

            // Check if body is complete based on Content-Length
            let headerStr = String(data: buffer[buffer.startIndex..<headerEnd.upperBound], encoding: .utf8) ?? ""
            let contentLength = extractContentLength(from: headerStr)
            let bodyReceived = buffer.count - headerEnd.upperBound

            if bodyReceived >= contentLength {
                Task { @MainActor in
                    await CanvasServer.shared.handleRawRequest(buffer, connection: connection, expectedToken: token)
                }
            } else {
                receiveData(from: connection, token: token, accumulated: buffer)
            }
        }
    }

    private nonisolated static func extractContentLength(from headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(val) ?? 0
            }
        }
        return 0
    }

    // MARK: - Request Processing (MainActor)

    func handleRawRequest(_ data: Data, connection: NWConnection, expectedToken: String) async {
        guard let raw = String(data: data, encoding: .utf8) else {
            sendResponse(connection, status: 400, body: #"{"error":"bad request"}"#)
            return
        }

        let req = parseHTTP(raw)

        if req.path != "/health" {
            guard (req.headers["x-canvas-token"] ?? "") == expectedToken else {
                sendResponse(connection, status: 401, body: #"{"error":"unauthorized"}"#)
                return
            }
        }

        requestCount += 1
        canvasLog("[CanvasServer] \(req.method) \(req.path)")

        switch (req.method, req.path) {
        case ("GET", "/health"):
            await handleHealth(connection)

        case ("POST", "/api/message"):
            await handleMessage(connection, body: req.body)

        case ("GET", "/api/sessions"):
            await handleSessions(connection)

        case let ("GET", p) where p.hasPrefix("/api/messages/"):
            let sid = String(p.dropFirst("/api/messages/".count)).components(separatedBy: "?").first ?? ""
            await handleMessages(connection, sessionId: sid)

        default:
            sendResponse(connection, status: 404, body: #"{"error":"not found"}"#)
        }
    }

    // MARK: - Route Handlers

    private func handleHealth(_ connection: NWConnection) async {
        let count = (try? TreeStore.shared.listTrees())?.count ?? 0
        let uptime = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        sendResponse(connection, status: 200,
                     body: #"{"status":"ok","sessions":\#(count),"uptime":\#(uptime)}"#)
    }

    private func handleSessions(_ connection: NWConnection) async {
        do {
            let trees = try TreeStore.shared.listTrees()
            let iso = ISO8601DateFormatter()
            let items = trees.map { t in
                #"{"id":"\#(t.id)","name":"\#(esc(t.name))","project":"\#(esc(t.project ?? ""))","updated_at":"\#(iso.string(from: t.updatedAt))","message_count":\#(t.messageCount)}"#
            }
            sendResponse(connection, status: 200, body: "[\(items.joined(separator: ","))]")
        } catch {
            sendResponse(connection, status: 500,
                         body: #"{"error":"\#(esc(error.localizedDescription))"}"#)
        }
    }

    private func handleMessages(_ connection: NWConnection, sessionId: String) async {
        guard !sessionId.isEmpty else {
            sendResponse(connection, status: 400, body: #"{"error":"missing session id"}"#)
            return
        }
        do {
            let msgs = try MessageStore.shared.getMessages(sessionId: sessionId, limit: 100)
            let items = msgs.map { m in
                #"{"role":"\#(m.role.rawValue)","content":"\#(esc(m.content))"}"#
            }
            sendResponse(connection, status: 200, body: "[\(items.joined(separator: ","))]")
        } catch {
            sendResponse(connection, status: 500,
                         body: #"{"error":"\#(esc(error.localizedDescription))"}"#)
        }
    }

    // MARK: - Message / SSE Handler

    private func handleMessage(_ connection: NWConnection, body: String) async {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendResponse(connection, status: 400, body: #"{"error":"invalid JSON"}"#)
            return
        }

        let content = (json["content"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let incomingSessionId = json["session_id"] as? String
        let project = json["project"] as? String

        guard !content.isEmpty else {
            sendResponse(connection, status: 400, body: #"{"error":"content required"}"#)
            return
        }

        // Resolve session
        let resolved: (sessionId: String, branchId: String, treeId: String, isNew: Bool)
        do {
            resolved = try resolveSession(
                sessionId: incomingSessionId, project: project, firstMessage: content)
        } catch {
            sendResponse(connection, status: 500,
                         body: #"{"error":"session error: \#(esc(error.localizedDescription))"}"#)
            return
        }

        // Persist user message
        do {
            _ = try MessageStore.shared.sendMessage(
                sessionId: resolved.sessionId, role: .user, content: content)
        } catch {
            canvasLog("[CanvasServer] Failed to persist user message: \(error)")
        }

        // Open SSE stream
        sendSSEHeader(connection)

        let ctx = ProviderSendContext(
            message: content,
            sessionId: resolved.sessionId,
            branchId: resolved.branchId,
            model: CortanaConstants.defaultModel,
            workingDirectory: nil,
            project: project,
            parentSessionId: nil,
            isNewSession: resolved.isNew
        )

        var fullResponse = ""

        // Prefer AnthropicAPIProvider for server-routed messages —
        // ClaudeCodeProvider requires an active desktop Claude session.
        let provider = ProviderManager.shared.providers.first { $0.identifier == "claude-code" }
            ?? ProviderManager.shared.activeProvider

        guard let provider else {
            sendSSEChunk(connection, #"{"error":"No LLM provider available"}"#)
            sendSSEClose(connection)
            return
        }

        canvasLog("[CanvasServer] Using provider: \(provider.identifier)")

        for await event in provider.send(context: ctx) {
            switch event {
            case .text(let token):
                fullResponse += token
                sendSSEChunk(connection, #"{"token":"\#(esc(token))"}"#)

            case .done:
                do {
                    _ = try MessageStore.shared.sendMessage(
                        sessionId: resolved.sessionId, role: .assistant, content: fullResponse)
                    try TreeStore.shared.updateTreeTimestamp(resolved.treeId)
                } catch {
                    canvasLog("[CanvasServer] Failed to persist assistant message: \(error)")
                }
                sendSSEChunk(connection, #"{"done":true,"response":"\#(esc(fullResponse))"}"#)
                sendSSEClose(connection)
                return

            case .error(let msg):
                sendSSEChunk(connection, #"{"error":"\#(esc(msg))"}"#)
                sendSSEClose(connection)
                return

            case .toolStart(let name, _):
                sendSSEChunk(connection, #"{"tool_start":"\#(esc(name))"}"#)

            case .toolEnd(let name, _, let isError):
                sendSSEChunk(connection, #"{"tool_end":"\#(esc(name))","error":\#(isError)}"#)
            }
        }

        // Stream ended without .done
        if !fullResponse.isEmpty {
            _ = try? MessageStore.shared.sendMessage(
                sessionId: resolved.sessionId, role: .assistant, content: fullResponse)
        }
        sendSSEClose(connection)
    }

    // MARK: - Session Resolution

    private func resolveSession(
        sessionId incomingId: String?,
        project: String?,
        firstMessage: String
    ) throws -> (sessionId: String, branchId: String, treeId: String, isNew: Bool) {

        if let sid = incomingId, !sid.isEmpty,
           let branch = try TreeStore.shared.getBranchBySessionId(sid),
           let branchSid = branch.sessionId {
            return (sessionId: branchSid, branchId: branch.id, treeId: branch.treeId, isNew: false)
        }

        let treeName = project.map { "Telegram • \($0)" } ?? "Telegram"
        let tree = try TreeStore.shared.createTree(name: treeName, project: project)
        let branch = try TreeStore.shared.createBranch(
            treeId: tree.id, title: String(firstMessage.prefix(60)))
        guard let sid = branch.sessionId else {
            throw NSError(domain: "CanvasServer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Branch \(branch.id) has no sessionId — session continuity would be broken"])
        }
        return (sessionId: sid, branchId: branch.id, treeId: tree.id, isNew: true)
    }

    // MARK: - HTTP Parser

    private struct ParsedRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: String
    }

    private func parseHTTP(_ raw: String) -> ParsedRequest {
        let sections = raw.components(separatedBy: "\r\n\r\n")
        let headerBlock = sections.first ?? ""
        let body = sections.dropFirst().joined(separator: "\r\n\r\n")

        let lines = headerBlock.components(separatedBy: "\r\n")
        let tokens = (lines.first ?? "").components(separatedBy: " ")
        let method = tokens.first ?? "GET"
        let rawPath = tokens.count > 1 ? tokens[1] : "/"
        let path = rawPath.components(separatedBy: "?").first ?? rawPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.range(of: ":") {
                let key = String(line[line.startIndex..<colon.lowerBound])
                    .lowercased().trimmingCharacters(in: .whitespaces)
                let val = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }

        return ParsedRequest(method: method, path: path, headers: headers, body: body)
    }

    // MARK: - Response Helpers

    private func sendResponse(
        _ connection: NWConnection,
        status: Int,
        body: String,
        contentType: String = "application/json"
    ) {
        let bodyBytes = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status) \(statusText(status))\r\n" +
                     "Content-Type: \(contentType)\r\n" +
                     "Content-Length: \(bodyBytes.count)\r\n" +
                     "Access-Control-Allow-Origin: *\r\n" +
                     "Connection: close\r\n\r\n"
        var resp = header.data(using: .utf8)!
        resp.append(bodyBytes)
        connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendSSEHeader(_ connection: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\n" +
                     "Content-Type: text/event-stream\r\n" +
                     "Cache-Control: no-cache\r\n" +
                     "Access-Control-Allow-Origin: *\r\n" +
                     "Connection: keep-alive\r\n\r\n"
        if let data = header.data(using: .utf8) {
            connection.send(content: data, completion: .idempotent)
        }
    }

    private func sendSSEChunk(_ connection: NWConnection, _ payload: String) {
        if let data = "data: \(payload)\n\n".data(using: .utf8) {
            connection.send(content: data, completion: .idempotent)
        }
    }

    private func sendSSEClose(_ connection: NWConnection) {
        connection.send(content: Data(), isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func statusText(_ code: Int) -> String {
        [200: "OK", 400: "Bad Request", 401: "Unauthorized",
         404: "Not Found", 500: "Internal Server Error"][code] ?? "Unknown"
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }
}
