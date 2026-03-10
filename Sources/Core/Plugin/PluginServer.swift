import Foundation
import Network

// MARK: - PluginServer

/// Cortana plugin server for World Tree.
///
/// Exposes World Tree's conversation trees, projects, and jobs as MCP tools
/// to the Cortana daemon. Binds to localhost:9400.
///
/// Discovery: on startup this server drops a manifest file at
/// ~/.cortana/state/plugins/world-tree.json which the daemon picks up
/// at next launch.
///
/// Endpoints:
///   GET  /manifest  — plugin identity (daemon discovery + health check)
///   GET  /health    — liveness probe
///   POST /mcp       — MCP JSON-RPC 2.0
///   POST /events    — daemon event receiver (fire-and-forget)
///
/// MCP tools:
///   world_tree_list_trees      — list all conversation trees
///   world_tree_get_messages    — get message history for a session
///   world_tree_list_projects   — list discovered development projects
///   world_tree_list_active_jobs — list queued/running background jobs
@MainActor
final class PluginServer: ObservableObject {
    static let shared = PluginServer()

    static let port: UInt16 = 9400
    static let pluginID = "world-tree"
    static let pluginName = "World Tree"
    static let pluginVersion = "1.1.0"
    static let toolCount = 7
    static let enabledKey = AppConstants.pluginServerEnabledKey

    @Published private(set) var isRunning = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastError: String?

    private var listener: NWListener?
    private let networkQueue = DispatchQueue(label: "world-tree.plugin-server", qos: .utility)

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        do {
            guard let nwPort = NWEndpoint.Port(rawValue: Self.port) else {
                lastError = "Invalid port: \(Self.port)"
                wtLog("[PluginServer] Cannot start: invalid port \(Self.port)")
                return
            }
            let listener = try NWListener(using: .tcp, on: nwPort)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
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
                        self.writeManifestFile()
                        wtLog("[PluginServer] Ready on port \(Self.port)")
                    case .failed(let error):
                        self.isRunning = false
                        self.lastError = error.localizedDescription
                        wtLog("[PluginServer] Failed: \(error)")
                    case .cancelled:
                        self.isRunning = false
                        wtLog("[PluginServer] Stopped")
                    default:
                        break
                    }
                }
            }

            listener.start(queue: networkQueue)
        } catch {
            lastError = error.localizedDescription
            wtLog("[PluginServer] Listener init failed: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Manifest File (daemon auto-discovery)

    /// Drops ~/.cortana/state/plugins/world-tree.json so the daemon
    /// discovers this plugin at next startup without manual configuration.
    private func writeManifestFile() {
        let pluginsDir = URL(fileURLWithPath: AppConstants.pluginManifestDir)
        let manifestFile = pluginsDir.appendingPathComponent("world-tree.json")
        try? FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        let manifest = """
        {
          "id": "\(Self.pluginID)",
          "name": "\(Self.pluginName)",
          "version": "\(Self.pluginVersion)",
          "url": "http://localhost:\(Self.port)",
          "mcp_path": "/mcp",
          "events_path": "/events",
          "tool_count": \(Self.toolCount)
        }
        """
        try? manifest.data(using: .utf8)?.write(to: manifestFile)
        wtLog("[PluginServer] Manifest written to \(manifestFile.path)")
    }

    // MARK: - Connection Entry (MainActor)

    private func beginConnection(_ connection: NWConnection) {
        connection.start(queue: networkQueue)
        Self.receiveData(from: connection, accumulated: Data())
    }

    // MARK: - Receive Loop (nonisolated)

    private nonisolated static func receiveData(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, isComplete, error in
            if let error {
                wtLog("[PluginServer] Receive error: \(error)")
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let chunk { buffer.append(chunk) }

            let terminator = Data("\r\n\r\n".utf8)
            guard let headerEnd = buffer.range(of: terminator) else {
                if isComplete { connection.cancel() }
                else { receiveData(from: connection, accumulated: buffer) }
                return
            }

            let headerStr = String(data: buffer[buffer.startIndex..<headerEnd.upperBound], encoding: .utf8) ?? ""
            let contentLength = extractContentLength(from: headerStr)
            let bodyReceived = buffer.count - headerEnd.upperBound

            if bodyReceived >= contentLength {
                Task { @MainActor in
                    await PluginServer.shared.handleRequest(buffer, connection: connection)
                }
            } else {
                receiveData(from: connection, accumulated: buffer)
            }
        }
    }

    private nonisolated static func extractContentLength(from headers: String) -> Int {
        extractHTTPContentLength(from: headers)
    }

    // MARK: - Request Dispatch (MainActor)

    func handleRequest(_ data: Data, connection: NWConnection) async {
        guard let raw = String(data: data, encoding: .utf8) else {
            sendResponse(connection, status: 400, body: #"{"error":"bad request"}"#)
            return
        }

        let req = parseHTTP(raw)

        switch (req.method, req.path) {
        case ("GET", "/manifest"):
            handleManifest(connection)

        case ("GET", "/health"):
            handleHealth(connection)

        case ("POST", "/mcp"):
            await handleMCP(connection, body: req.body)

        case ("POST", "/events"):
            handleEvents(connection, body: req.body)

        default:
            sendResponse(connection, status: 404, body: #"{"error":"not found"}"#)
        }
    }

    // MARK: - Route Handlers

    private func handleManifest(_ connection: NWConnection) {
        let body = """
        {"id":"\(Self.pluginID)","name":"\(Self.pluginName)","version":"\(Self.pluginVersion)","url":"http://localhost:\(Self.port)","mcp_path":"/mcp","events_path":"/events"}
        """
        sendResponse(connection, status: 200, body: body)
    }

    private func handleHealth(_ connection: NWConnection) {
        sendResponse(connection, status: 200, body: #"{"status":"ok"}"#)
    }

    private func handleEvents(_ connection: NWConnection, body: String) {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = json["type"] as? String {
            wtLog("[PluginServer] Daemon event: \(type)")
        }
        sendResponse(connection, status: 200, body: #"{"ok":true}"#)
    }

    // MARK: - MCP JSON-RPC Handler

    private func handleMCP(_ connection: NWConnection, body: String) async {
        guard !body.isEmpty else {
            sendResponse(connection, status: 400, body: #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Empty request body"}}"#)
            return
        }

        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendResponse(connection, status: 400, body: #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error: invalid JSON"}}"#)
            return
        }

        let method = json["method"] as? String ?? ""
        guard !method.isEmpty else {
            let rpcId: String
            if let n = json["id"] as? Int { rpcId = "\(n)" }
            else if let s = json["id"] as? String { rpcId = "\"\(esc(s))\"" }
            else { rpcId = "null" }
            sendResponse(connection, status: 200, body: #"{"jsonrpc":"2.0","id":\#(rpcId),"error":{"code":-32600,"message":"Invalid request: missing method"}}"#)
            return
        }
        // id may be Int or String per JSON-RPC spec; preserve as string for embedding
        let rpcId: String
        if let n = json["id"] as? Int { rpcId = "\(n)" }
        else if let s = json["id"] as? String { rpcId = "\"\(esc(s))\"" }
        else { rpcId = "null" }

        wtLog("[PluginServer] handleMCP: method=\(method)")
        switch method {
        case "initialize":
            let result = """
            {"jsonrpc":"2.0","id":\(rpcId),"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"id":"\(Self.pluginID)","name":"\(Self.pluginName)","version":"\(Self.pluginVersion)"}}}
            """
            sendResponse(connection, status: 200, body: result)

        case "tools/list":
            sendResponse(connection, status: 200, body: toolsListResponse(id: rpcId))

        case "tools/call":
            let params = json["params"] as? [String: Any] ?? [:]
            let toolName = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            wtLog("[PluginServer] callTool start: \(toolName)")
            let result = await callTool(name: toolName, arguments: arguments, id: rpcId)
            wtLog("[PluginServer] callTool done: \(toolName)")
            sendResponse(connection, status: 200, body: result)

        case let m where m.hasPrefix("notifications/"):
            // MCP notifications have no id and require no response, but HTTP needs a reply.
            sendResponse(connection, status: 200, body: #"{"jsonrpc":"2.0","result":{}}"#)

        default:
            let error = #"{"jsonrpc":"2.0","id":\#(rpcId),"error":{"code":-32601,"message":"Method not found"}}"#
            sendResponse(connection, status: 200, body: error)
        }
    }

    // MARK: - Tool Definitions

    private func toolsListResponse(id: String) -> String {
        // swiftlint:disable line_length
        let tools = #"""
        [
          {"name":"world_tree_list_trees","description":"List all conversation trees in World Tree. Returns id, name, project, updated_at, message_count.","inputSchema":{"type":"object","properties":{},"required":[]}},
          {"name":"world_tree_get_messages","description":"Get the message history for a conversation branch by session ID.","inputSchema":{"type":"object","properties":{"session_id":{"type":"string","description":"Branch session ID (from world_tree_list_trees)"},"limit":{"type":"number","description":"Max messages to return (default 50)"}},"required":["session_id"]}},
          {"name":"world_tree_list_projects","description":"List all discovered development projects with type, git branch, and dirty state.","inputSchema":{"type":"object","properties":{},"required":[]}},
          {"name":"world_tree_list_active_jobs","description":"List queued and running background jobs in World Tree.","inputSchema":{"type":"object","properties":{},"required":[]}},
          {"name":"world_tree_list_pen_assets","description":"List .pen design files imported into World Tree for a project. Returns id, file_name, frame_count, node_count, last_parsed.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Project name to filter by (optional — omit for all projects)"}},"required":[]}},
          {"name":"world_tree_get_frame_ticket","description":"Get the ticket linked to a specific Pencil design frame. Returns ticket_id, title, status, priority, acceptance_criteria, and file_path. Returns null if no link exists.","inputSchema":{"type":"object","properties":{"frame_id":{"type":"string","description":"Pencil node ID of the frame"},"pen_asset_id":{"type":"string","description":"ID of the pen_asset containing the frame"}},"required":["frame_id","pen_asset_id"]}},
          {"name":"world_tree_list_ticket_frames","description":"List all Pencil design frames linked to a ticket. Use this mid-implementation to find the design frames you need to build.","inputSchema":{"type":"object","properties":{"ticket_id":{"type":"string","description":"Ticket ID (e.g. TASK-067)"},"project":{"type":"string","description":"Project name"}},"required":["ticket_id","project"]}}
        ]
        """#
        // swiftlint:enable line_length
        return #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":\#(tools)}}"#
    }

    // MARK: - Tool Execution

    private func callTool(name: String, arguments: [String: Any], id: String) async -> String {
        switch name {
        case "world_tree_list_trees":
            return await toolListTrees(id: id)

        case "world_tree_get_messages":
            let sessionId = arguments["session_id"] as? String ?? ""
            let limit: Int
            if let n = arguments["limit"] as? Int { limit = n }
            else if let d = arguments["limit"] as? Double { limit = Int(d) }
            else { limit = 50 }
            return await toolGetMessages(sessionId: sessionId, limit: limit, id: id)

        case "world_tree_list_projects":
            return await toolListProjects(id: id)

        case "world_tree_list_active_jobs":
            return toolListActiveJobs(id: id)

        case "world_tree_list_pen_assets":
            let project = arguments["project"] as? String
            return await toolListPenAssets(project: project, id: id)

        case "world_tree_get_frame_ticket":
            let frameId = arguments["frame_id"] as? String ?? ""
            let assetId = arguments["pen_asset_id"] as? String ?? ""
            return await toolGetFrameTicket(frameId: frameId, assetId: assetId, id: id)

        case "world_tree_list_ticket_frames":
            let ticketId = arguments["ticket_id"] as? String ?? ""
            let project = arguments["project"] as? String ?? ""
            return await toolListTicketFrames(ticketId: ticketId, project: project, id: id)

        default:
            return #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32602,"message":"Unknown tool: \#(esc(name))"}}"#
        }
    }

    private func toolListTrees(id: String) async -> String {
        do {
            let trees = try TreeStore.shared.getTrees()
            guard !trees.isEmpty else {
                return textResult(id: id, text: "[]")
            }
            let iso = ISO8601DateFormatter()
            let items = trees.map { t in
                #"{"id":"\#(esc(t.id))","name":"\#(esc(t.name))","project":"\#(esc(t.project ?? ""))","updated_at":"\#(iso.string(from: t.updatedAt))","message_count":\#(t.messageCount)}"#
            }
            let payload = "[\(items.joined(separator: ","))]"
            return textResult(id: id, text: payload)
        } catch {
            wtLog("[PluginServer] toolListTrees error: \(error)")
            return mcpError(id: id, message: "Failed to list trees: \(error.localizedDescription)")
        }
    }

    private func toolGetMessages(sessionId: String, limit: Int, id: String) async -> String {
        guard !sessionId.isEmpty else {
            return mcpError(id: id, message: "session_id is required")
        }
        let clampedLimit = max(1, min(limit, 500))
        do {
            let msgs = try MessageStore.shared.getMessages(sessionId: sessionId, limit: clampedLimit)
            guard !msgs.isEmpty else {
                return textResult(id: id, text: "[]")
            }
            let items = msgs.map { m in
                #"{"role":"\#(m.role.rawValue)","content":"\#(esc(m.content))"}"#
            }
            let payload = "[\(items.joined(separator: ","))]"
            return textResult(id: id, text: payload)
        } catch {
            wtLog("[PluginServer] toolGetMessages error: \(error)")
            return mcpError(id: id, message: "Failed to get messages: \(error.localizedDescription)")
        }
    }

    private func toolListProjects(id: String) async -> String {
        do {
            let projects = try ProjectCache().getAll()
            guard !projects.isEmpty else {
                return textResult(id: id, text: "[]")
            }
            let iso = ISO8601DateFormatter()
            let items = projects.map { p in
                let branch = p.gitBranch.map { "\"\(esc($0))\"" } ?? "null"
                let dirty = p.gitDirty ? "true" : "false"
                return #"{"name":"\#(esc(p.name))","path":"\#(esc(p.path))","type":"\#(p.type.rawValue)","git_branch":\#(branch),"git_dirty":\#(dirty),"last_modified":"\#(iso.string(from: p.lastModified))"}"#
            }
            let payload = "[\(items.joined(separator: ","))]"
            return textResult(id: id, text: payload)
        } catch {
            wtLog("[PluginServer] toolListProjects error: \(error)")
            return mcpError(id: id, message: "Failed to list projects: \(error.localizedDescription)")
        }
    }

    private func toolListActiveJobs(id: String) -> String {
        let jobs = JobQueue.shared.activeJobs()
        guard !jobs.isEmpty else {
            return textResult(id: id, text: "[]")
        }
        let iso = ISO8601DateFormatter()
        let items = jobs.map { j in
            #"{"id":"\#(esc(j.id))","type":"\#(esc(j.type))","command":"\#(esc(j.command))","status":"\#(j.status.rawValue)","created_at":"\#(iso.string(from: j.createdAt))"}"#
        }
        let payload = "[\(items.joined(separator: ","))]"
        return textResult(id: id, text: payload)
    }

    // MARK: - Pencil Design Tools

    private func toolListPenAssets(project: String?, id: String) async -> String {
        do {
            let assets = try await DatabaseManager.shared.asyncRead { db in
                if let project {
                    return try PenAsset.fetchAll(db, sql: """
                        SELECT * FROM pen_assets WHERE project = ? ORDER BY file_name ASC
                        """, arguments: [project])
                } else {
                    return try PenAsset.fetchAll(db, sql: "SELECT * FROM pen_assets ORDER BY project, file_name")
                }
            }
            guard !assets.isEmpty else { return textResult(id: id, text: "[]") }
            let items = assets.map { a in
                """
                {"id":"\(esc(a.id))","project":"\(esc(a.project))","file_name":"\(esc(a.fileName))","frame_count":\(a.frameCount),"node_count":\(a.nodeCount),"last_parsed":"\(esc(a.lastParsed ?? ""))"}
                """
                .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return textResult(id: id, text: "[\(items.joined(separator: ","))]")
        } catch {
            wtLog("[PluginServer] toolListPenAssets error: \(error)")
            return mcpError(id: id, message: "Failed to list pen assets: \(error.localizedDescription)")
        }
    }

    private func toolGetFrameTicket(frameId: String, assetId: String, id: String) async -> String {
        guard !frameId.isEmpty, !assetId.isEmpty else {
            return mcpError(id: id, message: "frame_id and pen_asset_id are required")
        }
        // Fetch raw data on background thread, format on MainActor after
        struct FrameTicketData: Sendable {
            let ticketId: String
            let title: String
            let status: String
            let priority: String
            let acceptanceCriteria: String?
            let filePath: String?
        }
        do {
            let data: FrameTicketData? = try await DatabaseManager.shared.asyncRead { db in
                guard let link = try PenFrameLink.fetchOne(db, sql: """
                    SELECT * FROM pen_frame_links WHERE asset_id = ? AND frame_id = ?
                    """, arguments: [assetId, frameId]),
                      let ticketId = link.ticketId,
                      let ticket = try Ticket.fetchOne(db, sql: "SELECT * FROM canvas_tickets WHERE id = ?", arguments: [ticketId])
                else { return nil }
                return FrameTicketData(
                    ticketId: ticket.id,
                    title: ticket.title,
                    status: ticket.status,
                    priority: ticket.priority,
                    acceptanceCriteria: ticket.acceptanceCriteria,
                    filePath: ticket.filePath
                )
            }
            guard let d = data else { return textResult(id: id, text: "null") }
            let criteria = esc(d.acceptanceCriteria ?? "[]")
            let filePath = d.filePath.map { "\"\(esc($0))\"" } ?? "null"
            let payload = """
            {"ticket_id":"\(esc(d.ticketId))","title":"\(esc(d.title))","status":"\(esc(d.status))","priority":"\(esc(d.priority))","acceptance_criteria":\(criteria),"file_path":\(filePath)}
            """.trimmingCharacters(in: .whitespacesAndNewlines)
            return textResult(id: id, text: payload)
        } catch {
            wtLog("[PluginServer] toolGetFrameTicket error: \(error)")
            return mcpError(id: id, message: "Failed to get frame ticket: \(error.localizedDescription)")
        }
    }

    private func toolListTicketFrames(ticketId: String, project: String, id: String) async -> String {
        guard !ticketId.isEmpty else {
            return mcpError(id: id, message: "ticket_id is required")
        }
        struct FrameRow: Sendable {
            let frameId: String
            let frameName: String
            let fileName: String
            let penAssetId: String
        }
        do {
            let frames: [FrameRow] = try await DatabaseManager.shared.asyncRead { db in
                let links = try PenFrameLink.fetchAll(db,
                    sql: "SELECT * FROM pen_frame_links WHERE ticket_id = ?",
                    arguments: [ticketId])
                return try links.compactMap { link -> FrameRow? in
                    guard let asset = try PenAsset.fetchOne(db,
                        sql: "SELECT * FROM pen_assets WHERE id = ?",
                        arguments: [link.assetId]) else { return nil }
                    if !project.isEmpty, asset.project != project { return nil }
                    return FrameRow(
                        frameId: link.frameId,
                        frameName: link.frameName ?? "",
                        fileName: asset.fileName,
                        penAssetId: asset.id
                    )
                }
            }
            guard !frames.isEmpty else { return textResult(id: id, text: "[]") }
            let items = frames.map { f in
                """
                {"frame_id":"\(esc(f.frameId))","frame_name":"\(esc(f.frameName))","file_name":"\(esc(f.fileName))","pen_asset_id":"\(esc(f.penAssetId))"}
                """.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return textResult(id: id, text: "[\(items.joined(separator: ","))]")
        } catch {
            wtLog("[PluginServer] toolListTicketFrames error: \(error)")
            return mcpError(id: id, message: "Failed to list ticket frames: \(error.localizedDescription)")
        }
    }

    // MARK: - HTTP Parser

    private struct ParsedRequest {
        let method: String
        let path: String
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

        return ParsedRequest(method: method, path: path, body: body)
    }

    // MARK: - Response Helper

    private func sendResponse(_ connection: NWConnection, status: Int, body: String) {
        let bodyBytes = body.data(using: .utf8) ?? Data()
        let statusText = [200: "OK", 400: "Bad Request", 404: "Not Found",
                          500: "Internal Server Error"][status] ?? "Unknown"
        let header = "HTTP/1.1 \(status) \(statusText)\r\n" +
                     "Content-Type: application/json\r\n" +
                     "Content-Length: \(bodyBytes.count)\r\n" +
                     "Access-Control-Allow-Origin: http://localhost\r\n" +
                     "Connection: close\r\n\r\n"
        var resp = Data(header.utf8)
        resp.append(bodyBytes)
        connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - MCP Response Helpers

    /// Wraps a text payload as an MCP tools/call result.
    private func textResult(id: String, text: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"text","text":"\#(esc(text))"}]}}"#
    }

    private func mcpError(id: String, message: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"\#(esc(message))"}}"#
    }

    // MARK: - String Escaping

    private func esc(_ s: String) -> String { escapeJSONString(s) }
}
