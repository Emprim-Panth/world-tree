import Foundation
import Network

// MARK: - WorldTreeServer

/// HTTP/SSE server that exposes Canvas sessions to external clients.
///
/// Telegram bot and MacBook Canvas (remote mode) POST messages and receive
/// Claude tokens as Server-Sent Events. All endpoints except `/health`
/// require the `x-worldtree-token` header.
///
/// Port 5865. Token stored in UserDefaults under `cortana.serverToken`.
@MainActor
final class WorldTreeServer: ObservableObject {
    static let shared = WorldTreeServer()

    static let port: UInt16 = 5865
    /// Native WebSocket port (NWProtocolWebSocket) — iOS connects here.
    /// One above the HTTP port so clients derive it as `port + 1`.
    static let wsPort: UInt16 = 5866
    static let tokenKey = AppConstants.serverTokenKey   // kept for Settings UI compat — no longer enforced
    static let enabledKey = AppConstants.serverEnabledKey
    static let bonjourEnabledKey = AppConstants.bonjourEnabledKey

    static let maxWebSocketConnections = 10

    @Published private(set) var isRunning = false
    @Published private(set) var requestCount = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var ngrokPublicURL: String?
    @Published private(set) var webSocketClients: [String: WebSocketClient] = [:]
    /// Service name currently advertised via Bonjour, or `nil` when not advertising.
    @Published private(set) var bonjourServiceName: String?

    private var listener: NWListener?
    private var wsListener: NWListener?
    private let networkQueue = DispatchQueue(label: "cortana.canvas-server", qos: .userInitiated)
    private var pingTask: Task<Void, Never>?
    /// Tracks last WebSocket connection time per remote IP for reconnect throttling.
    private var lastWSConnectionTime: [String: Date] = [:]
    private static let wsReconnectThrottleSeconds: TimeInterval = 2.0

    /// Exponential backoff for listener restart — prevents restart storm on port conflict.
    private var restartAttempts = 0
    private let maxRestartAttempts = 5

    private static let iso8601 = ISO8601DateFormatter()

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        do {
            guard let nwPort = NWEndpoint.Port(rawValue: Self.port) else {
                lastError = "Invalid port: \(Self.port)"
                wtLog("[WorldTreeServer] Cannot start: invalid port \(Self.port)")
                return
            }
            let listener = try NWListener(using: .tcp, on: nwPort)
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
                        self.restartAttempts = 0
                        self.writeStateFile(ngrokURL: nil)
                        wtLog("[WorldTreeServer] Ready on port \(Self.port)")
                        // Discover ngrok tunnel URL (if running) after a short delay
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                            await self?.discoverAndWriteNgrokURL()
                        }
                    case .failed(let error):
                        self.isRunning = false
                        self.lastError = error.localizedDescription
                        self.restartAttempts += 1
                        if self.restartAttempts <= self.maxRestartAttempts {
                            let delay = min(5 * Int(pow(2.0, Double(self.restartAttempts - 1))), 300)
                            wtLog("[WorldTreeServer] Failed: \(error) — restarting in \(delay)s (attempt \(self.restartAttempts)/\(self.maxRestartAttempts))")
                            Task { @MainActor [weak self] in
                                try? await Task.sleep(for: .seconds(delay))
                                self?.start()
                            }
                        } else {
                            wtLog("[WorldTreeServer] Failed: \(error) — giving up after \(self.maxRestartAttempts) attempts")
                        }
                    case .cancelled:
                        self.isRunning = false
                        wtLog("[WorldTreeServer] Stopped")
                    default:
                        break
                    }
                }
            }

            listener.start(queue: networkQueue)
            startNativeWSListener()
        } catch {
            lastError = error.localizedDescription
            wtLog("[WorldTreeServer] Listener init failed: \(error)")
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

        wsListener?.cancel()
        wsListener = nil
        listener?.cancel()
        listener = nil
        isRunning = false
        ngrokPublicURL = nil
        bonjourServiceName = nil
        removeStateFile()
    }

    // MARK: - Bonjour

    /// Whether Bonjour advertising is enabled. Defaults to `true` when the key has never been set.
    var isBonjourEnabled: Bool {
        guard UserDefaults.standard.object(forKey: Self.bonjourEnabledKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: Self.bonjourEnabledKey)
    }

    /// The short hostname component (e.g. "Ryans-Mac-Studio" from a fully-qualified name).
    var shortHostname: String {
        ProcessInfo.processInfo.hostName.components(separatedBy: ".").first
            ?? ProcessInfo.processInfo.hostName
    }

    /// Attaches a `_worldtree._tcp.` Bonjour advertisement to `listener` when enabled.
    /// Must be called before `listener.start()`.
    /// Sets `bonjourServiceName` so callers can confirm advertising is active.
    func configureBonjour(on listener: NWListener) {
        guard isBonjourEnabled else {
            wtLog("[WorldTreeServer] Bonjour disabled — skipping advertisement")
            return
        }

        let name = "\(shortHostname),\(Self.wsPort)"
        var txt = NWTXTRecord()
        txt["version"] = "1"
        txt["name"]    = "World Tree"
        txt["wsPath"]  = "/ws"

        listener.service = NWListener.Service(
            name: name,
            type: "_worldtree._tcp.",
            domain: nil,
            txtRecord: txt
        )
        bonjourServiceName = name
        wtLog("[WorldTreeServer] Bonjour advertising as '\(name)' (_worldtree._tcp.)")
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
            "started_at": Self.iso8601.string(from: Date())
        ]
        if let ngrok = ngrokURL {
            state["ngrok_url"] = ngrok
            wtLog("[WorldTreeServer] ngrok URL: \(ngrok)")
        }
        if let data = try? JSONSerialization.data(withJSONObject: state, options: .prettyPrinted) {
            try? data.write(to: stateFile, options: .atomic)
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
        wtLog("[WorldTreeServer] No ngrok tunnel detected — remote access unavailable")
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
        // Extract remote IP for rate limiting (best-effort — may be nil for Unix sockets)
        let remoteIP = Self.remoteIP(from: connection)
        // Hand off to nonisolated receive loop
        Self.receiveData(from: connection, remoteIP: remoteIP, accumulated: Data(), server: self)
    }

    /// Extract the dotted-decimal (or colon-delimited) IP from an NWConnection endpoint.
    private nonisolated static func remoteIP(from connection: NWConnection) -> String {
        switch connection.endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr): return "\(addr)"
            case .ipv6(let addr): return "\(addr)"
            default:              return host.debugDescription
            }
        default:
            return "unknown"
        }
    }

    // MARK: - Receive Loop (nonisolated)

    /// Accumulates raw TCP bytes until a complete HTTP/1.1 request arrives, then dispatches.
    /// Runs on NWConnection's callback queue — no MainActor access here.
    private nonisolated static func receiveData(
        from connection: NWConnection,
        remoteIP: String,
        accumulated: Data,
        server: WorldTreeServer
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, isComplete, error in
            if let error {
                wtLog("[WorldTreeServer] Receive error: \(error)")
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let chunk { buffer.append(chunk) }

            // Reject oversized requests (1 MB limit) to prevent memory exhaustion
            if buffer.count > 1_048_576 {
                wtLog("[WorldTreeServer] Request too large (\(buffer.count) bytes) — dropping")
                connection.cancel()
                return
            }

            // Wait for the full HTTP header block (\r\n\r\n terminator)
            let terminator = Data("\r\n\r\n".utf8)
            guard let headerEnd = buffer.range(of: terminator) else {
                if isComplete { connection.cancel() }
                else { receiveData(from: connection, remoteIP: remoteIP, accumulated: buffer, server: server) }
                return
            }

            // Check if body is complete based on Content-Length
            let headerStr = String(data: buffer[buffer.startIndex..<headerEnd.upperBound], encoding: .utf8) ?? ""
            let contentLength = extractContentLength(from: headerStr)
            let bodyReceived = buffer.count - headerEnd.upperBound

            if bodyReceived >= contentLength {
                Task { @MainActor [weak server] in
                    await server?.handleRawRequest(buffer, connection: connection, remoteIP: remoteIP)
                }
            } else {
                receiveData(from: connection, remoteIP: remoteIP, accumulated: buffer, server: server)
            }
        }
    }

    private nonisolated static func extractContentLength(from headers: String) -> Int {
        extractHTTPContentLength(from: headers)
    }

    // MARK: - Request Processing (MainActor)

    func handleRawRequest(
        _ data: Data,
        connection: NWConnection,
        remoteIP: String = "unknown"
    ) async {
        guard let raw = String(data: data, encoding: .utf8) else {
            sendResponse(connection, status: 400, body: #"{"error":"bad request"}"#)
            return
        }

        let req = parseHTTP(raw)

        // WebSocket upgrade on the HTTP port is no longer supported.
        // All WebSocket clients connect to port 5866 (NWProtocolWebSocket).
        if req.headers["upgrade"]?.lowercased() == "websocket" {
            sendResponse(connection, status: 426, body: #"{"error":"WebSocket upgrade not supported on HTTP port — connect to port \#(Self.wsPort) instead"}"#)
            return
        }

        requestCount += 1
        wtLog("[WorldTreeServer] \(req.method) \(req.path)")

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
        let count = (try? TreeStore.shared.getTrees())?.count ?? 0
        let uptime = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        sendResponse(connection, status: 200,
                     body: #"{"status":"ok","sessions":\#(count),"uptime":\#(uptime)}"#)
    }

    private func handleSessions(_ connection: NWConnection) async {
        do {
            let trees = try TreeStore.shared.getTrees()
            let iso = Self.iso8601
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
        let source = json["source"] as? String

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
                wtLog("[WorldTreeServer] Injected Telegram context summary (\(summary.count) chars)")
            } catch {
                wtLog("[WorldTreeServer] Failed to inject context summary: \(error)")
            }
        }

        // Signal the Canvas app to open the terminal for this branch (work requests)
        if openTerminal {
            NotificationCenter.default.post(
                name: .canvasServerRequestedTerminalOpen,
                object: resolved.branchId
            )
            wtLog("[WorldTreeServer] Requested terminal open for branch \(resolved.branchId)")
        }

        // Persist user message
        do {
            _ = try MessageStore.shared.sendMessage(
                sessionId: resolved.sessionId, role: .user, content: content)
        } catch {
            wtLog("[WorldTreeServer] Failed to persist user message: \(error)")
        }

        // Notify UI about external message source (e.g. Telegram) — already @MainActor
        if let source, !source.isEmpty {
            NotificationCenter.default.post(
                name: .canvasServerExternalMessage,
                object: nil,
                userInfo: ["source": source, "sessionId": resolved.sessionId]
            )
        }

        // Open SSE stream
        sendSSEHeader(connection)

        // Resolve working directory from tree metadata
        let treeWorkingDir: String? = {
            guard let tree = try? TreeStore.shared.getTree(resolved.treeId) else { return nil }
            return tree.workingDirectory
        }()

        // Build fully-enriched context (ConversationScorer + MemoryService + project context)
        let ctx = SendContextBuilder.build(
            message: content,
            sessionId: resolved.sessionId,
            branchId: resolved.branchId,
            workingDirectory: treeWorkingDir,
            project: project
        )

        var fullResponse = ""

        // Route through daemon channel if enabled and reachable.
        // Falls back to direct ProviderManager if daemon is unavailable.
        let daemonEnabled = UserDefaults.standard.bool(forKey: AppConstants.daemonChannelEnabledKey)
        let daemonConnected = DaemonService.shared.isConnected

        let eventStream: AsyncStream<BridgeEvent>
        if daemonEnabled && daemonConnected {
            wtLog("[WorldTreeServer] Routing through daemon channel")
            eventStream = await DaemonChannel.shared.send(
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
            wtLog("[WorldTreeServer] Using provider: \(provider.identifier)")
            eventStream = provider.send(context: ctx)
        }

        for await event in eventStream {
            switch event {
            case .text(let token):
                fullResponse += token
                sendSSEChunk(connection, #"{"token":"\#(esc(token))"}"#)

            case .done(let usage):
                // Record token usage
                if usage.totalInputTokens > 0 || usage.totalOutputTokens > 0 {
                    let resolvedModel = UserDefaults.standard.string(forKey: AppConstants.defaultModelKey) ?? AppConstants.defaultModel
                    TokenStore.shared.record(
                        sessionId: resolved.sessionId,
                        branchId: resolved.branchId,
                        inputTokens: usage.totalInputTokens,
                        outputTokens: usage.totalOutputTokens,
                        cacheHitTokens: usage.cacheHitTokens,
                        model: resolvedModel
                    )
                }

                do {
                    _ = try MessageStore.shared.sendMessage(
                        sessionId: resolved.sessionId, role: .assistant, content: fullResponse)
                    try TreeStore.shared.updateTreeTimestamp(resolved.treeId)
                } catch {
                    wtLog("[WorldTreeServer] Failed to persist assistant message: \(error)")
                }
                // Only send length — clients already have the full text from token events.
                // Sending the entire response again doubled peak memory usage.
                sendSSEChunk(connection, #"{"done":true,"response_length":\#(fullResponse.count)}"#)
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
            throw NSError(domain: "WorldTreeServer", code: -1,
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
        // Split header block from body at first \r\n\r\n using range(of:) to
        // avoid allocating an array of all sections and re-joining the body.
        let headerBlock: Substring
        let body: String
        if let sep = raw.range(of: "\r\n\r\n") {
            headerBlock = raw[raw.startIndex..<sep.lowerBound]
            body = String(raw[sep.upperBound...])
        } else {
            headerBlock = raw[...]
            body = ""
        }

        // Parse request line — split on first two spaces only via index scanning
        // instead of components(separatedBy:) which allocates an array.
        let requestLine: Substring
        if let firstCRLF = headerBlock.range(of: "\r\n") {
            requestLine = headerBlock[headerBlock.startIndex..<firstCRLF.lowerBound]
        } else {
            requestLine = headerBlock
        }

        let method: String
        let rawPath: String
        if let firstSpace = requestLine.firstIndex(of: " ") {
            method = String(requestLine[requestLine.startIndex..<firstSpace])
            let afterMethod = requestLine.index(after: firstSpace)
            if let secondSpace = requestLine[afterMethod...].firstIndex(of: " ") {
                rawPath = String(requestLine[afterMethod..<secondSpace])
            } else {
                rawPath = String(requestLine[afterMethod...])
            }
        } else {
            method = "GET"
            rawPath = "/"
        }

        let path: String
        if let qmark = rawPath.firstIndex(of: "?") {
            path = String(rawPath[rawPath.startIndex..<qmark])
        } else {
            path = rawPath
        }

        // Parse only the headers we actually use — avoids allocating a full
        // dictionary for every header in the request.
        var headers: [String: String] = [:]
        var searchStart = headerBlock.startIndex
        if let firstCRLF = headerBlock.range(of: "\r\n") {
            searchStart = firstCRLF.upperBound
        }
        let headerLines = headerBlock[searchStart...]
        for line in headerLines.split(separator: "\r\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].lowercased()
                .trimmingCharacters(in: .whitespaces)
            // Only store headers the server actually reads
            guard key == "content-length" || key == "content-type" ||
                  key == "authorization" || key == "x-worldtree-token" ||
                  key == "upgrade" || key == "connection" ||
                  key == "sec-websocket-key" || key == "sec-websocket-version"
            else { continue }
            let val = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[key] = val
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
        var resp = Data(header.utf8)
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
         404: "Not Found", 429: "Too Many Requests", 500: "Internal Server Error",
         503: "Service Unavailable"][code] ?? "Unknown"
    }

    private func esc(_ s: String) -> String { escapeJSONString(s) }
}

// MARK: - WebSocket Client

/// Tracked state for one connected WebSocket client.
struct WebSocketClient {
    let id: String                          // UUID
    let connection: NWConnection
    let wsConnection: (any WSClientSendable)?
    let connectedAt: Date
    var clientName: String?
    var subscribedTreeId: String?
    var subscribedBranchId: String?
    var lastPongAt: Date
}

// MARK: - WebSocket Client Management

extension WorldTreeServer {

    /// Remove a WebSocket client (disconnect or close).
    private func removeWebSocketClient(_ clientId: String, code: UInt16, reason: String?) {
        guard webSocketClients.removeValue(forKey: clientId) != nil else { return }
        // Clean up any branch subscriptions for this client
        SubscriptionManager.shared.remove(clientId: clientId)
        wtLog("[WorldTreeServer] WebSocket client disconnected: \(clientId) (code: \(code), remaining: \(webSocketClients.count))")

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

        wtLog("[WorldTreeServer] WS[\(clientId.prefix(8))] → \(msg.type)")

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
        case .createTree:
            handleWSCreateTree(clientId: clientId, message: msg)
        case .createBranch:
            handleWSCreateBranch(clientId: clientId, message: msg)
        case .renameTree:
            handleWSRenameTree(clientId: clientId, message: msg)
        case .deleteTree:
            handleWSDeleteTree(clientId: clientId, message: msg)
        case .renameBranch:
            handleWSRenameBranch(clientId: clientId, message: msg)
        case .deleteBranch:
            handleWSDeleteBranch(clientId: clientId, message: msg)
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

        wtLog("[WorldTreeServer] WS[\(clientId.prefix(8))] subscribed to tree:\(sub.treeId.prefix(8)) branch:\(sub.branchId.prefix(8))")

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
            let trees = try TreeStore.shared.getTrees()
            let iso = Self.iso8601
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
            let iso = Self.iso8601
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
            let iso = Self.iso8601
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

        wtLog("[WorldTreeServer] WS[\(clientId.prefix(8))] send_message to branch:\(req.branchId.prefix(8))")

        // Persist user message — if this fails, do NOT dispatch to LLM
        guard let _ = try? MessageStore.shared.sendMessage(sessionId: sessionId, role: .user, content: req.content) else {
            sendWSError(to: clientId, code: "persist_failed", message: "Failed to save message — not sent to AI", id: message.id)
            return
        }

        // Acknowledge receipt immediately so the client knows the message was accepted
        let ack = WSMessage(type: "message_received", id: message.id)
        if let json = ack.toJSON() {
            client.wsConnection?.send(text: json)
        }

        // Resolve the tree's project field for working directory resolution.
        // getTree throws and returns T?, so try? produces T?? — flatMap collapses it.
        let treeProject = (try? TreeStore.shared.getTree(branch.treeId)).flatMap { $0 }?.project

        // Dispatch to LLM via ClaudeBridge — handles Friday routing with automatic fallback
        // to direct provider when the daemon is unavailable or returns an error.
        let isNew = (try? MessageStore.shared.getMessages(sessionId: sessionId, limit: 2))?.count == 1
        let ctx = ProviderSendContext(
            message: req.content,
            sessionId: sessionId,
            branchId: req.branchId,
            model: AppConstants.defaultModel,
            workingDirectory: nil,
            project: treeProject ?? branch.title,
            parentSessionId: nil,
            isNewSession: isNew
        )

        Task { @MainActor in
            let eventStream = ClaudeBridge.shared.send(context: ctx)
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
            wtLog("[WorldTreeServer] WS[\(clientId.prefix(8))] stream cancelled for branch:\(branchId.prefix(8))")
        }

        let ack = WSMessage(type: "stream_cancelled", id: message.id)
        if let json = ack.toJSON() {
            webSocketClients[clientId]?.wsConnection?.send(text: json)
        }
    }

    private func handleWSCreateTree(clientId: String, message: WSMessage) {
        guard let client = webSocketClients[clientId] else { return }

        guard let payload = message.payload,
              let req = try? payload.decode(as: WSCreateTreePayload.self),
              !req.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendWSError(to: clientId, code: "invalid_payload", message: "create_tree requires a non-empty name", id: message.id)
            return
        }

        do {
            _ = try TreeStore.shared.createTree(name: req.name.trimmingCharacters(in: .whitespacesAndNewlines), project: req.project)
            let trees = try TreeStore.shared.getTrees()
            let iso = Self.iso8601
            let treeInfos = trees.map { t in
                WSTreeInfo(id: t.id, name: t.name, project: t.project, updatedAt: iso.string(from: t.updatedAt), messageCount: t.messageCount)
            }
            let response = WSMessage.treesList(trees: treeInfos, id: message.id)
            if let json = response.toJSON() { client.wsConnection?.send(text: json) }
        } catch {
            sendWSError(to: clientId, code: "internal_error", message: error.localizedDescription, id: message.id)
        }
    }

    private func handleWSCreateBranch(clientId: String, message: WSMessage) {
        guard let client = webSocketClients[clientId] else { return }

        guard let payload = message.payload,
              let req = try? payload.decode(as: WSCreateBranchPayload.self) else {
            sendWSError(to: clientId, code: "invalid_payload", message: "create_branch requires treeId", id: message.id)
            return
        }

        do {
            _ = try TreeStore.shared.createBranch(
                treeId: req.treeId,
                parentBranch: req.parentBranchId,
                forkFromMessage: req.fromMessageId,
                title: req.title
            )
            guard let tree = try TreeStore.shared.getTree(req.treeId) else {
                sendWSError(to: clientId, code: "not_found", message: "Tree not found", id: message.id)
                return
            }
            let iso = Self.iso8601
            let branchInfos = tree.branches.map { b in
                WSBranchInfo(id: b.id, treeId: b.treeId, title: b.title, status: b.status.rawValue, branchType: b.branchType.rawValue, createdAt: iso.string(from: b.createdAt), updatedAt: iso.string(from: b.updatedAt))
            }
            let response = WSMessage.branchesList(branches: branchInfos, id: message.id)
            if let json = response.toJSON() { client.wsConnection?.send(text: json) }
        } catch {
            sendWSError(to: clientId, code: "internal_error", message: error.localizedDescription, id: message.id)
        }
    }

    private func handleWSRenameTree(clientId: String, message: WSMessage) {
        guard let client = webSocketClients[clientId] else { return }

        guard let payload = message.payload,
              let req = try? payload.decode(as: WSRenameTreePayload.self),
              !req.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendWSError(to: clientId, code: "invalid_payload", message: "rename_tree requires treeId and name", id: message.id)
            return
        }

        do {
            try TreeStore.shared.renameTree(req.treeId, name: req.name.trimmingCharacters(in: .whitespacesAndNewlines))
            let trees = try TreeStore.shared.getTrees()
            let iso = Self.iso8601
            let treeInfos = trees.map { t in
                WSTreeInfo(id: t.id, name: t.name, project: t.project, updatedAt: iso.string(from: t.updatedAt), messageCount: t.messageCount)
            }
            let response = WSMessage.treesList(trees: treeInfos, id: message.id)
            if let json = response.toJSON() { client.wsConnection?.send(text: json) }
        } catch {
            sendWSError(to: clientId, code: "internal_error", message: error.localizedDescription, id: message.id)
        }
    }

    private func handleWSDeleteTree(clientId: String, message: WSMessage) {
        guard let client = webSocketClients[clientId] else { return }

        guard let payload = message.payload,
              let req = try? payload.decode(as: WSDeleteTreePayload.self) else {
            sendWSError(to: clientId, code: "invalid_payload", message: "delete_tree requires treeId", id: message.id)
            return
        }

        do {
            try TreeStore.shared.deleteTree(req.treeId)
            let trees = try TreeStore.shared.getTrees()
            let iso = Self.iso8601
            let treeInfos = trees.map { t in
                WSTreeInfo(id: t.id, name: t.name, project: t.project, updatedAt: iso.string(from: t.updatedAt), messageCount: t.messageCount)
            }
            let response = WSMessage.treesList(trees: treeInfos, id: message.id)
            if let json = response.toJSON() { client.wsConnection?.send(text: json) }
        } catch {
            sendWSError(to: clientId, code: "internal_error", message: error.localizedDescription, id: message.id)
        }
    }

    private func handleWSRenameBranch(clientId: String, message: WSMessage) {
        guard let client = webSocketClients[clientId] else { return }

        guard let payload = message.payload,
              let req = try? payload.decode(as: WSRenameBranchPayload.self),
              !req.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendWSError(to: clientId, code: "invalid_payload", message: "rename_branch requires branchId and title", id: message.id)
            return
        }

        do {
            guard let branch = try TreeStore.shared.getBranch(req.branchId) else {
                sendWSError(to: clientId, code: "not_found", message: "Branch not found", id: message.id)
                return
            }
            try TreeStore.shared.renameBranch(req.branchId, title: req.title.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let tree = try TreeStore.shared.getTree(branch.treeId) else {
                sendWSError(to: clientId, code: "not_found", message: "Tree not found", id: message.id)
                return
            }
            let iso = Self.iso8601
            let branchInfos = tree.branches.map { b in
                WSBranchInfo(id: b.id, treeId: b.treeId, title: b.title, status: b.status.rawValue, branchType: b.branchType.rawValue, createdAt: iso.string(from: b.createdAt), updatedAt: iso.string(from: b.updatedAt))
            }
            let response = WSMessage.branchesList(branches: branchInfos, id: message.id)
            if let json = response.toJSON() { client.wsConnection?.send(text: json) }
        } catch {
            sendWSError(to: clientId, code: "internal_error", message: error.localizedDescription, id: message.id)
        }
    }

    private func handleWSDeleteBranch(clientId: String, message: WSMessage) {
        guard let client = webSocketClients[clientId] else { return }

        guard let payload = message.payload,
              let req = try? payload.decode(as: WSDeleteBranchPayload.self) else {
            sendWSError(to: clientId, code: "invalid_payload", message: "delete_branch requires branchId", id: message.id)
            return
        }

        do {
            guard let branch = try TreeStore.shared.getBranch(req.branchId) else {
                sendWSError(to: clientId, code: "not_found", message: "Branch not found", id: message.id)
                return
            }
            let treeId = branch.treeId
            try TreeStore.shared.deleteBranch(req.branchId)
            guard let tree = try TreeStore.shared.getTree(treeId) else {
                // Tree may have been deleted if last branch was removed; send updated tree list
                let trees = try TreeStore.shared.getTrees()
                let iso = Self.iso8601
                let treeInfos = trees.map { t in
                    WSTreeInfo(id: t.id, name: t.name, project: t.project, updatedAt: iso.string(from: t.updatedAt), messageCount: t.messageCount)
                }
                let response = WSMessage.treesList(trees: treeInfos, id: message.id)
                if let json = response.toJSON() { client.wsConnection?.send(text: json) }
                return
            }
            let iso = Self.iso8601
            let branchInfos = tree.branches.map { b in
                WSBranchInfo(id: b.id, treeId: b.treeId, title: b.title, status: b.status.rawValue, branchType: b.branchType.rawValue, createdAt: iso.string(from: b.createdAt), updatedAt: iso.string(from: b.updatedAt))
            }
            let response = WSMessage.branchesList(branches: branchInfos, id: message.id)
            if let json = response.toJSON() { client.wsConnection?.send(text: json) }
        } catch {
            sendWSError(to: clientId, code: "internal_error", message: error.localizedDescription, id: message.id)
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
    /// Uses SubscriptionManager's O(1) branch→clients index instead of scanning all connections.
    func broadcastToSubscribers(branchId: String, message: WSMessage) {
        let subscribers = SubscriptionManager.shared.subscribers(for: branchId)
        guard !subscribers.isEmpty, let json = message.toJSON() else { return }
        for clientId in subscribers {
            guard let client = webSocketClients[clientId] else {
                // Client disappeared — clean up stale subscription
                SubscriptionManager.shared.remove(clientId: clientId)
                continue
            }
            client.wsConnection?.send(text: json)
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
                wtLog("[WorldTreeServer] WebSocket client \(id.prefix(8)) pong timeout — closing")
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

    // MARK: - WebSocket Listener (Port 5866)
    //
    // All WebSocket clients (desktop and iOS) connect here.
    // Uses NWProtocolWebSocket — Network.framework handles RFC 6455 handshake and framing.
    // Auth: first message must be {"type":"auth","token":"<token>"}, with 10s timeout.

    private func startNativeWSListener() {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        guard let wsPort = NWEndpoint.Port(rawValue: Self.wsPort) else {
            wtLog("[WorldTreeServer] Invalid WebSocket port: \(Self.wsPort)")
            return
        }
        do {
            let wsl = try NWListener(using: params, on: wsPort)
            wsListener = wsl
            configureBonjour(on: wsl)

            wsl.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.handleNativeWSConnection(connection) }
            }

            wsl.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        wtLog("[WorldTreeServer] Native WS ready on port \(Self.wsPort)")
                    case .failed(let error):
                        wtLog("[WorldTreeServer] Native WS failed: \(error) — restarting in 5s")
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(5))
                            self?.startNativeWSListener()
                        }
                    case .cancelled:
                        wtLog("[WorldTreeServer] Native WS stopped")
                    default:
                        break
                    }
                }
            }

            wsl.start(queue: networkQueue)
        } catch {
            wtLog("[WorldTreeServer] Native WS listener init failed: \(error)")
        }
    }

    private func handleNativeWSConnection(_ connection: NWConnection) {
        guard webSocketClients.count < Self.maxWebSocketConnections else {
            connection.cancel()
            return
        }

        // Reconnect throttle: prevent churn from rapid connect/disconnect cycles
        let endpointIP = Self.remoteIP(from: connection)
        let now = Date()
        if let lastTime = lastWSConnectionTime[endpointIP],
           now.timeIntervalSince(lastTime) < Self.wsReconnectThrottleSeconds {
            wtLog("[WorldTreeServer] WS throttled for \(endpointIP) — reconnecting too fast")
            connection.cancel()
            return
        }
        lastWSConnectionTime[endpointIP] = now

        // Periodic cleanup to prevent unbounded growth
        if lastWSConnectionTime.count > 50 {
            lastWSConnectionTime = lastWSConnectionTime.filter {
                now.timeIntervalSince($0.value) < 60
            }
        }

        // Wait for the NWProtocolWebSocket handshake to complete before registering.
        // The handshake happens asynchronously after connection.start(); we must not
        // call readNext() until the connection is .ready or receives deliver an error.
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { @MainActor [weak self] in
                    self?.registerNativeWSClient(connection)
                }
            case .failed(let error):
                // ECONNRESET during cleanup is expected — don't log as a failure
                if !Self.isConnectionResetError(error) {
                    wtLog("[WorldTreeServer] Native WS handshake failed: \(error)")
                }
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }

        connection.start(queue: networkQueue)
    }

    /// Check if an NWError is ECONNRESET (errno 54) — expected during disconnect cleanup.
    private nonisolated static func isConnectionResetError(_ error: NWError) -> Bool {
        if case .posix(let code) = error, code == .ECONNRESET {
            return true
        }
        return false
    }

    private func registerNativeWSClient(_ connection: NWConnection) {
        let clientId = UUID().uuidString
        let wsConn = NativeWebSocketConnection(id: clientId, connection: connection)

        let client = WebSocketClient(
            id: clientId,
            connection: connection,
            wsConnection: wsConn,
            connectedAt: Date(),
            lastPongAt: Date()
        )

        webSocketClients[clientId] = client
        wtLog("[WorldTreeServer] WS client connected: \(clientId.prefix(8)) (total: \(webSocketClients.count))")

        wsConn.onMessage = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleWebSocketMessage(clientId: clientId, text: text)
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

        wsConn.startReading()
        startPingTimerIfNeeded()
    }

}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a Telegram work request wants a terminal open for a branch.
    /// object: branchId (String)
    static let canvasServerRequestedTerminalOpen = Notification.Name("canvasServerRequestedTerminalOpen")

    /// Posted when a message arrives from an external source (e.g. Telegram).
    /// userInfo: ["source": "telegram", "sessionId": String]
    static let canvasServerExternalMessage = Notification.Name("canvasServerExternalMessage")
}
