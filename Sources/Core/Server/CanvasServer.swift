import Foundation
import Network
import CryptoKit

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

    static let maxWebSocketConnections = 10

    @Published private(set) var isRunning = false
    @Published private(set) var requestCount = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var ngrokPublicURL: String?
    @Published private(set) var webSocketClients: [String: WebSocketClient] = [:]

    private var listener: NWListener?
    private let networkQueue = DispatchQueue(label: "cortana.canvas-server", qos: .userInitiated)
    private var pingTask: Task<Void, Never>?

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
        // Stop WebSocket ping timer
        pingTask?.cancel()
        pingTask = nil

        // Close all WebSocket connections
        for client in webSocketClients.values {
            client.wsConnection?.sendCloseAndDisconnect(code: 1001, reason: "Server shutting down")
        }
        webSocketClients.removeAll()

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

        // Detect WebSocket upgrade before normal auth — WS uses token from query param or header
        if req.path == "/ws",
           req.headers["upgrade"]?.lowercased() == "websocket",
           req.headers["connection"]?.lowercased().contains("upgrade") == true {
            // Auth: accept token from query parameter or header
            let token = req.queryParam("token") ?? req.headers["x-canvas-token"] ?? ""
            guard token == expectedToken else {
                sendResponse(connection, status: 401, body: #"{"error":"unauthorized"}"#)
                return
            }
            await handleWebSocketUpgrade(connection, request: req)
            return
        }

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
        let contextSummary = json["context_summary"] as? String
        let openTerminal = (json["open_terminal"] as? Bool) == true

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

        // Inject Telegram context summary as a system message on new sessions
        // This is the "walk up to the Mac" feature — Evan never has to repeat himself
        if let summary = contextSummary, resolved.isNew, !summary.isEmpty {
            do {
                _ = try MessageStore.shared.sendMessage(
                    sessionId: resolved.sessionId, role: .system, content: summary)
                canvasLog("[CanvasServer] Injected Telegram context summary (\(summary.count) chars)")
            } catch {
                canvasLog("[CanvasServer] Failed to inject context summary: \(error)")
            }
        }

        // Signal the Canvas app to open the terminal for this branch (work requests)
        if openTerminal {
            NotificationCenter.default.post(
                name: .canvasServerRequestedTerminalOpen,
                object: resolved.branchId
            )
            canvasLog("[CanvasServer] Requested terminal open for branch \(resolved.branchId)")
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

        // Prefer Friday daemon for server-routed messages (full identity + memory context).
        // Falls back to direct ProviderManager if daemon is unavailable.
        let fridayEnabled = UserDefaults.standard.bool(forKey: CortanaConstants.fridayChannelEnabledKey)
        let daemonConnected = DaemonService.shared.isConnected

        let eventStream: AsyncStream<BridgeEvent>
        if fridayEnabled && daemonConnected {
            canvasLog("[CanvasServer] Routing through Friday daemon")
            eventStream = await FridayChannel.shared.send(
                text: content,
                project: project,
                branchId: resolved.branchId,
                sessionId: resolved.sessionId
            )
        } else {
            let provider = ProviderManager.shared.activeProvider
            guard let provider else {
                sendSSEChunk(connection, #"{"error":"No LLM provider available"}"#)
                sendSSEClose(connection)
                return
            }
            canvasLog("[CanvasServer] Using provider: \(provider.identifier)")
            eventStream = provider.send(context: ctx)
        }

        for await event in eventStream {
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

    struct ParsedRequest {
        let method: String
        let path: String
        let rawPath: String  // Includes query string
        let headers: [String: String]
        let body: String

        /// Extract a query parameter value by key.
        func queryParam(_ key: String) -> String? {
            guard let queryStart = rawPath.firstIndex(of: "?") else { return nil }
            let query = String(rawPath[rawPath.index(after: queryStart)...])
            for pair in query.components(separatedBy: "&") {
                let parts = pair.components(separatedBy: "=")
                if parts.count == 2, parts[0] == key {
                    return parts[1].removingPercentEncoding ?? parts[1]
                }
            }
            return nil
        }
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

        return ParsedRequest(method: method, path: path, rawPath: rawPath, headers: headers, body: body)
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
        [101: "Switching Protocols", 200: "OK", 400: "Bad Request", 401: "Unauthorized",
         404: "Not Found", 500: "Internal Server Error", 503: "Service Unavailable"][code] ?? "Unknown"
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }
}

// MARK: - WebSocket Client

/// Tracked state for one connected WebSocket client.
struct WebSocketClient {
    let id: String                          // UUID
    let connection: NWConnection
    let wsConnection: WebSocketConnection?
    let connectedAt: Date
    var clientName: String?
    var subscribedTreeId: String?
    var subscribedBranchId: String?
    var lastPongAt: Date
}

// MARK: - WebSocket Upgrade & Management

extension CanvasServer {

    /// Handle the WebSocket upgrade handshake (called from handleRawRequest).
    func handleWebSocketUpgrade(_ connection: NWConnection, request: ParsedRequest) async {
        // Enforce max connections
        guard webSocketClients.count < Self.maxWebSocketConnections else {
            sendResponse(connection, status: 503, body: #"{"error":"too many WebSocket connections"}"#)
            return
        }

        // Validate required WebSocket headers
        guard let wsKey = request.headers["sec-websocket-key"], !wsKey.isEmpty else {
            sendResponse(connection, status: 400, body: #"{"error":"missing Sec-WebSocket-Key"}"#)
            return
        }

        guard request.headers["sec-websocket-version"] == "13" else {
            sendResponse(connection, status: 400, body: #"{"error":"unsupported WebSocket version"}"#)
            return
        }

        // Send 101 Switching Protocols
        let upgradeData = WebSocketCodec.upgradeResponse(for: wsKey)
        connection.send(content: upgradeData, completion: .contentProcessed { [weak self] error in
            if let error {
                canvasLog("[CanvasServer] WebSocket upgrade send failed: \(error)")
                connection.cancel()
                return
            }
            // Transition to WebSocket frame mode on MainActor
            Task { @MainActor [weak self] in
                self?.registerWebSocketClient(connection)
            }
        })

        requestCount += 1
        canvasLog("[CanvasServer] WebSocket upgrade → /ws")
    }

    /// Register a new WebSocket client after successful upgrade.
    private func registerWebSocketClient(_ connection: NWConnection) {
        let clientId = UUID().uuidString
        let wsConn = WebSocketConnection(id: clientId, connection: connection)

        let client = WebSocketClient(
            id: clientId,
            connection: connection,
            wsConnection: wsConn,
            connectedAt: Date(),
            lastPongAt: Date()
        )

        webSocketClients[clientId] = client
        canvasLog("[CanvasServer] WebSocket client connected: \(clientId) (total: \(webSocketClients.count))")

        // Set up callbacks
        wsConn.onMessage = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.handleWebSocketMessage(clientId: clientId, text: text)
            }
        }

        wsConn.onClose = { [weak self] code, reason in
            Task { @MainActor [weak self] in
                self?.removeWebSocketClient(clientId, code: code, reason: reason)
            }
        }

        wsConn.onPong = { [weak self] in
            Task { @MainActor [weak self] in
                self?.webSocketClients[clientId]?.lastPongAt = Date()
            }
        }

        // Start reading frames
        wsConn.startReading()

        // Start ping timer if not already running
        startPingTimerIfNeeded()
    }

    /// Remove a WebSocket client (disconnect or close).
    private func removeWebSocketClient(_ clientId: String, code: UInt16, reason: String?) {
        guard webSocketClients.removeValue(forKey: clientId) != nil else { return }
        canvasLog("[CanvasServer] WebSocket client disconnected: \(clientId) (code: \(code), remaining: \(webSocketClients.count))")

        // Stop ping timer if no clients remain
        if webSocketClients.isEmpty {
            pingTask?.cancel()
            pingTask = nil
        }
    }

    /// Handle an incoming text message from a WebSocket client.
    private func handleWebSocketMessage(clientId: String, text: String) {
        guard let client = webSocketClients[clientId] else { return }

        guard let msg = WSMessage.fromJSON(text) else {
            let errMsg = WSMessage.error(code: "invalid_message", message: "Could not parse JSON message")
            if let json = errMsg.toJSON() {
                client.wsConnection?.send(text: json)
            }
            return
        }

        canvasLog("[CanvasServer] WS[\(clientId.prefix(8))] → \(msg.type)")

        // Route by message type (protocol handling will be implemented in FRD-003 phase)
        // For now, acknowledge the message types and respond with appropriate structures
        guard let msgType = WSClientMessageType(rawValue: msg.type) else {
            let errMsg = WSMessage.error(code: "unknown_type", message: "Unknown message type: \(msg.type)", id: msg.id)
            if let json = errMsg.toJSON() {
                client.wsConnection?.send(text: json)
            }
            return
        }

        switch msgType {
        case .subscribe:
            handleWSSubscribe(clientId: clientId, message: msg)
        case .unsubscribe:
            handleWSUnsubscribe(clientId: clientId, message: msg)
        case .listTrees:
            handleWSListTrees(clientId: clientId, message: msg)
        case .listBranches:
            handleWSListBranches(clientId: clientId, message: msg)
        case .getMessages:
            handleWSGetMessages(clientId: clientId, message: msg)
        case .sendMessage:
            handleWSSendMessage(clientId: clientId, message: msg)
        case .cancelStream:
            handleWSCancelStream(clientId: clientId, message: msg)
        }
    }

    // MARK: - WebSocket Message Handlers

    private func handleWSSubscribe(clientId: String, message: WSMessage) {
        guard var client = webSocketClients[clientId] else { return }

        guard let payload = message.payload,
              let sub = try? payload.decode(as: WSSubscribePayload.self) else {
            sendWSError(to: clientId, code: "invalid_payload", message: "subscribe requires treeId and branchId", id: message.id)
            return
        }

        // Unsubscribe from previous (if any) — BR-002: one subscription at a time
        client.subscribedTreeId = sub.treeId
        client.subscribedBranchId = sub.branchId
        webSocketClients[clientId] = client

        canvasLog("[CanvasServer] WS[\(clientId.prefix(8))] subscribed to tree:\(sub.treeId.prefix(8)) branch:\(sub.branchId.prefix(8))")

        // Acknowledge
        let ack = WSMessage(type: "subscribed", id: message.id)
        if let json = ack.toJSON() {
            client.wsConnection?.send(text: json)
        }
    }

    private func handleWSUnsubscribe(clientId: String, message: WSMessage) {
        guard var client = webSocketClients[clientId] else { return }

        client.subscribedTreeId = nil
        client.subscribedBranchId = nil
        webSocketClients[clientId] = client

        let ack = WSMessage(type: "unsubscribed", id: message.id)
        if let json = ack.toJSON() {
            client.wsConnection?.send(text: json)
        }
    }

    private func handleWSListTrees(clientId: String, message: WSMessage) {
        guard let client = webSocketClients[clientId] else { return }

        do {
            let trees = try TreeStore.shared.listTrees()
            let iso = ISO8601DateFormatter()
            let treeInfos = trees.map { t in
                WSTreeInfo(
                    id: t.id,
                    name: t.name,
                    project: t.project,
                    updatedAt: iso.string(from: t.updatedAt),
                    messageCount: t.messageCount
                )
            }
            let response = WSMessage.treesList(trees: treeInfos, id: message.id)
            if let json = response.toJSON() {
                client.wsConnection?.send(text: json)
            }
        } catch {
            sendWSError(to: clientId, code: "internal_error", message: error.localizedDescription, id: message.id)
        }
    }

    private func handleWSListBranches(clientId: String, message: WSMessage) {
        guard let client = webSocketClients[clientId] else { return }

        guard let payload = message.payload,
              let req = try? payload.decode(as: WSListBranchesPayload.self) else {
            sendWSError(to: clientId, code: "invalid_payload", message: "list_branches requires treeId", id: message.id)
            return
        }

        do {
            let tree = try TreeStore.shared.getTree(req.treeId)
            guard let tree else {
                sendWSError(to: clientId, code: "not_found", message: "Tree not found", id: message.id)
                return
            }
            let iso = ISO8601DateFormatter()
            let branchInfos = tree.branches.map { b in
                WSBranchInfo(
                    id: b.id,
                    treeId: b.treeId,
                    title: b.title,
                    status: b.status.rawValue,
                    branchType: b.branchType.rawValue,
                    createdAt: iso.string(from: b.createdAt),
                    updatedAt: iso.string(from: b.updatedAt)
                )
            }
            let response = WSMessage.branchesList(branches: branchInfos, id: message.id)
            if let json = response.toJSON() {
                client.wsConnection?.send(text: json)
            }
        } catch {
            sendWSError(to: clientId, code: "internal_error", message: error.localizedDescription, id: message.id)
        }
    }

    private func handleWSGetMessages(clientId: String, message: WSMessage) {
        guard let client = webSocketClients[clientId] else { return }

        guard let payload = message.payload,
              let req = try? payload.decode(as: WSGetMessagesPayload.self) else {
            sendWSError(to: clientId, code: "invalid_payload", message: "get_messages requires branchId", id: message.id)
            return
        }

        do {
            // Resolve branchId to sessionId
            guard let branch = try TreeStore.shared.getBranch(req.branchId),
                  let sessionId = branch.sessionId else {
                sendWSError(to: clientId, code: "not_found", message: "Branch not found or has no session", id: message.id)
                return
            }

            let limit = req.limit ?? 50
            let msgs = try MessageStore.shared.getMessages(sessionId: sessionId, limit: limit)
            let iso = ISO8601DateFormatter()
            let msgInfos = msgs.map { m in
                WSMessageInfo(
                    id: m.id,
                    role: m.role.rawValue,
                    content: m.content,
                    createdAt: iso.string(from: m.createdAt)
                )
            }
            let response = WSMessage.messagesList(messages: msgInfos, id: message.id)
            if let json = response.toJSON() {
                client.wsConnection?.send(text: json)
            }
        } catch {
            sendWSError(to: clientId, code: "internal_error", message: error.localizedDescription, id: message.id)
        }
    }

    private func handleWSSendMessage(clientId: String, message: WSMessage) {
        guard let client = webSocketClients[clientId] else { return }

        guard let payload = message.payload,
              let req = try? payload.decode(as: WSSendMessagePayload.self) else {
            sendWSError(to: clientId, code: "invalid_payload", message: "send_message requires branchId and content", id: message.id)
            return
        }

        // BR-003: Must be subscribed to the target branch
        guard client.subscribedBranchId == req.branchId else {
            sendWSError(to: clientId, code: "not_subscribed", message: "Subscribe to the branch before sending messages", id: message.id)
            return
        }

        // Resolve branch → session
        guard let branch = try? TreeStore.shared.getBranch(req.branchId),
              let sessionId = branch.sessionId else {
            sendWSError(to: clientId, code: "not_found", message: "Branch not found or has no session", id: message.id)
            return
        }

        canvasLog("[CanvasServer] WS[\(clientId.prefix(8))] send_message to branch:\(req.branchId.prefix(8))")

        // Persist user message
        _ = try? MessageStore.shared.sendMessage(sessionId: sessionId, role: .user, content: req.content)

        // Acknowledge receipt immediately so the client knows the message was accepted
        let ack = WSMessage(type: "message_received", id: message.id)
        if let json = ack.toJSON() {
            client.wsConnection?.send(text: json)
        }

        // Dispatch to LLM and stream tokens to all subscribed WebSocket clients via TokenBroadcaster
        let isNew = (try? MessageStore.shared.getMessages(sessionId: sessionId, limit: 2))?.count == 1
        let ctx = ProviderSendContext(
            message: req.content,
            sessionId: sessionId,
            branchId: req.branchId,
            model: CortanaConstants.defaultModel,
            workingDirectory: nil,
            project: branch.title,
            parentSessionId: nil,
            isNewSession: isNew
        )

        let fridayEnabled = UserDefaults.standard.bool(forKey: CortanaConstants.fridayChannelEnabledKey)
        let daemonConnected = DaemonService.shared.isConnected

        Task { @MainActor [weak self] in
            guard self != nil else { return }

            let eventStream: AsyncStream<BridgeEvent>
            if fridayEnabled && daemonConnected {
                eventStream = await FridayChannel.shared.send(
                    text: req.content,
                    project: branch.title,
                    branchId: req.branchId,
                    sessionId: sessionId
                )
            } else {
                guard let provider = ProviderManager.shared.activeProvider else {
                    let errMsg = WSMessage.error(code: "no_provider", message: "No LLM provider available")
                    CanvasServer.shared.broadcastToSubscribers(branchId: req.branchId, message: errMsg)
                    return
                }
                eventStream = provider.send(context: ctx)
            }

            TokenBroadcaster.shared.broadcast(
                stream: eventStream,
                branchId: req.branchId,
                sessionId: sessionId
            )
        }
    }

    private func handleWSCancelStream(clientId: String, message: WSMessage) {
        // Resolve branchId from subscription or payload
        let branchId: String?
        if let payload = message.payload,
           let req = try? payload.decode(as: WSCancelStreamPayload.self) {
            branchId = req.branchId
        } else {
            branchId = webSocketClients[clientId]?.subscribedBranchId
        }

        if let branchId {
            TokenBroadcaster.shared.cancel(branchId: branchId)
            canvasLog("[CanvasServer] WS[\(clientId.prefix(8))] stream cancelled for branch:\(branchId.prefix(8))")
        }

        let ack = WSMessage(type: "stream_cancelled", id: message.id)
        if let json = ack.toJSON() {
            webSocketClients[clientId]?.wsConnection?.send(text: json)
        }
    }

    // MARK: - WebSocket Helpers

    /// Send an error message to a specific WebSocket client.
    private func sendWSError(to clientId: String, code: String, message: String?, id: String?) {
        guard let client = webSocketClients[clientId] else { return }
        let errMsg = WSMessage.error(code: code, message: message, id: id)
        if let json = errMsg.toJSON() {
            client.wsConnection?.send(text: json)
        }
    }

    /// Send a message to all WebSocket clients subscribed to a specific branch.
    func broadcastToSubscribers(branchId: String, message: WSMessage) {
        guard let json = message.toJSON() else { return }
        for client in webSocketClients.values {
            if client.subscribedBranchId == branchId {
                client.wsConnection?.send(text: json)
            }
        }
    }

    // MARK: - Ping/Pong Timer

    /// Start the ping timer (sends ping every 30s, closes connections that don't pong within 10s).
    private func startPingTimerIfNeeded() {
        guard pingTask == nil else { return }

        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                guard !Task.isCancelled else { break }
                self?.pingAllClients()
            }
        }
    }

    /// Send ping to all clients and close those that haven't ponged recently.
    private func pingAllClients() {
        let now = Date()
        var toRemove: [String] = []

        for (id, client) in webSocketClients {
            // If last pong was more than 40s ago (30s ping interval + 10s grace), connection is dead
            if now.timeIntervalSince(client.lastPongAt) > 40 {
                canvasLog("[CanvasServer] WebSocket client \(id.prefix(8)) pong timeout — closing")
                client.wsConnection?.sendCloseAndDisconnect(code: 1001, reason: "Pong timeout")
                toRemove.append(id)
            } else {
                client.wsConnection?.sendPing()
            }
        }

        for id in toRemove {
            webSocketClients.removeValue(forKey: id)
        }

        if webSocketClients.isEmpty {
            pingTask?.cancel()
            pingTask = nil
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a Telegram work request wants a terminal open for a branch.
    /// object: branchId (String)
    static let canvasServerRequestedTerminalOpen = Notification.Name("canvasServerRequestedTerminalOpen")
}
