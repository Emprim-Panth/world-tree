import Foundation
import GRDB
import Network

struct PluginMCPHTTPResponsePlan: Equatable {
    let status: Int
    let body: String?
    let contentType: String?
}

enum PluginMCPTransport {
    static func responsePlan(forMethod method: String, hasRequestID: Bool) -> PluginMCPHTTPResponsePlan? {
        guard !hasRequestID || method.hasPrefix("notifications/") else {
            return nil
        }

        // Streamable HTTP notifications are acknowledged with 202 and no JSON-RPC body.
        return PluginMCPHTTPResponsePlan(status: 202, body: nil, contentType: nil)
    }
}

private struct PluginTreeSummary: Sendable {
    let id: String
    let name: String
    let project: String?
    let updatedAt: Date
    let messageCount: Int
}

private struct PluginMessageSummary: Sendable {
    let role: String
    let content: String
}

private struct PluginProjectSummary: Sendable {
    let name: String
    let path: String
    let type: String
    let gitBranch: String?
    let gitDirty: Bool
    let lastModified: Date
}

private struct PluginJobSummary: Sendable {
    let id: String
    let type: String
    let command: String
    let status: String
    let createdAt: Date
}

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
///   world_tree_get_job         — fetch a specific job, including final output
///   world_tree_learn_video     — queue the local video learner as a background job
@MainActor
final class PluginServer: ObservableObject {
    static let shared = PluginServer()

    static let port: UInt16 = 9400
    static let pluginID = "world-tree"
    static let pluginName = "World Tree"
    static let pluginVersion = "1.1.0"
    static let toolCount = 10
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
        let hasRequestID = json.keys.contains("id")
        guard !method.isEmpty else {
            let rpcId: String
            if let n = json["id"] as? Int { rpcId = "\(n)" }
            else if let s = json["id"] as? String { rpcId = "\"\(esc(s))\"" }
            else { rpcId = "null" }
            sendResponse(connection, status: 200, body: #"{"jsonrpc":"2.0","id":\#(rpcId),"error":{"code":-32600,"message":"Invalid request: missing method"}}"#)
            return
        }
        if let responsePlan = PluginMCPTransport.responsePlan(forMethod: method, hasRequestID: hasRequestID) {
            sendResponse(
                connection,
                status: responsePlan.status,
                body: responsePlan.body,
                contentType: responsePlan.contentType
            )
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

        case "ping":
            sendResponse(connection, status: 200, body: #"{"jsonrpc":"2.0","id":\#(rpcId),"result":{}}"#)

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
          {"name":"world_tree_get_job","description":"Fetch a World Tree background job by ID, including current status, output preview, and error text.","inputSchema":{"type":"object","properties":{"job_id":{"type":"string","description":"Job ID from world_tree_list_active_jobs or world_tree_learn_video"}},"required":["job_id"]}},
          {"name":"world_tree_learn_video","description":"Queue the legacy local learn-video workflow as a World Tree job. Supports direct video URLs, playlists, search queries, transcript mode, and optional visual analysis.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Tracked World Tree project name. Used to resolve the working directory unless working_directory is provided."},"working_directory":{"type":"string","description":"Absolute path override for where the learner should run and store outputs."},"mode":{"type":"string","description":"video (default), full, visual, workflow, search, playlist, list, or status"},"input":{"type":"string","description":"YouTube URL, playlist URL, or search query depending on mode. Not needed for list/status."},"visual":{"type":"boolean","description":"For video/search modes, include Gemini visual analysis (--visual). Requires GOOGLE_API_KEY or GEMINI_API_KEY in World Tree's environment."},"max_results":{"type":"number","description":"Optional max results for search or playlist modes."}},"required":[]}},
          {"name":"world_tree_list_pen_assets","description":"List .pen design files imported into World Tree for a project. Returns id, file_name, frame_count, node_count, last_parsed.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Project name to filter by (optional — omit for all projects)"}},"required":[]}},
          {"name":"world_tree_get_frame_ticket","description":"Get the ticket linked to a specific Pencil design frame. Returns ticket_id, title, status, priority, acceptance_criteria, and file_path. Returns null if no link exists.","inputSchema":{"type":"object","properties":{"frame_id":{"type":"string","description":"Pencil node ID of the frame"},"pen_asset_id":{"type":"string","description":"ID of the pen_asset containing the frame"}},"required":["frame_id","pen_asset_id"]}},
          {"name":"world_tree_list_ticket_frames","description":"List all Pencil design frames linked to a ticket. Use this mid-implementation to find the design frames you need to build.","inputSchema":{"type":"object","properties":{"ticket_id":{"type":"string","description":"Ticket ID (e.g. TASK-067)"},"project":{"type":"string","description":"Project name"}},"required":["ticket_id","project"]}},
          {"name":"world_tree_frame_screenshot","description":"Capture a PNG screenshot of a specific Pencil design frame. Returns a base64-encoded image. Use this to visually inspect a design frame while implementing a ticket.","inputSchema":{"type":"object","properties":{"frame_id":{"type":"string","description":"Pencil node ID of the frame"},"pen_asset_id":{"type":"string","description":"ID from world_tree_list_pen_assets"}},"required":["frame_id","pen_asset_id"]}}
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
            return await toolListActiveJobs(id: id)

        case "world_tree_get_job":
            let jobId = arguments["job_id"] as? String ?? ""
            return await toolGetJob(jobId: jobId, id: id)

        case "world_tree_learn_video":
            let project = arguments["project"] as? String
            let workingDirectory = arguments["working_directory"] as? String
            let mode = arguments["mode"] as? String ?? "video"
            let input = arguments["input"] as? String
            let visual = arguments["visual"] as? Bool ?? false
            let maxResults: Int?
            if let n = arguments["max_results"] as? Int {
                maxResults = n
            } else if let d = arguments["max_results"] as? Double {
                maxResults = Int(d)
            } else {
                maxResults = nil
            }
            return await toolLearnVideo(
                project: project,
                workingDirectory: workingDirectory,
                mode: mode,
                input: input,
                visual: visual,
                maxResults: maxResults,
                id: id
            )

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

        case "world_tree_frame_screenshot":
            let frameId = arguments["frame_id"] as? String ?? ""
            guard !frameId.isEmpty else {
                return mcpError(id: id, message: "frame_id is required")
            }
            return await toolFrameScreenshot(frameId: frameId, id: id)

        default:
            return #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32602,"message":"Unknown tool: \#(esc(name))"}}"#
        }
    }

    private func toolListTrees(id: String) async -> String {
        do {
            let trees = try await DatabaseManager.shared.asyncRead { db in
                let sql = """
                    SELECT t.id, t.name, t.project, t.updated_at,
                        COALESCE(msg_agg.message_count, 0) as message_count
                    FROM canvas_trees t
                    LEFT JOIN (
                        SELECT b.tree_id, COUNT(m.id) as message_count, MAX(m.timestamp) as last_message_at
                        FROM canvas_branches b
                        JOIN messages m ON m.session_id = b.session_id
                        GROUP BY b.tree_id
                    ) msg_agg ON msg_agg.tree_id = t.id
                    WHERE t.archived = 0
                    ORDER BY COALESCE(msg_agg.last_message_at, t.updated_at) DESC
                    """
                return try Row.fetchAll(db, sql: sql).map { row in
                    PluginTreeSummary(
                        id: row["id"],
                        name: row["name"],
                        project: row["project"],
                        updatedAt: row["updated_at"] as? Date ?? Date(),
                        messageCount: row["message_count"] ?? 0
                    )
                }
            }
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
            let msgs = try await DatabaseManager.shared.asyncRead { db in
                let sql = """
                    SELECT * FROM (
                        SELECT m.role, m.content, m.timestamp
                        FROM messages m
                        WHERE m.session_id = ?
                        ORDER BY m.timestamp DESC
                        LIMIT ?
                    ) sub ORDER BY sub.timestamp ASC
                    """
                return try Row.fetchAll(db, sql: sql, arguments: [sessionId, clampedLimit]).map { row in
                    PluginMessageSummary(
                        role: row["role"],
                        content: row["content"]
                    )
                }
            }
            guard !msgs.isEmpty else {
                return textResult(id: id, text: "[]")
            }
            let items = msgs.map { m in
                #"{"role":"\#(esc(m.role))","content":"\#(esc(m.content))"}"#
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
            let projects = try await DatabaseManager.shared.asyncRead { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT name, path, type, git_branch, git_dirty, last_modified
                        FROM project_cache
                        ORDER BY last_modified DESC
                        """
                ).map { row in
                    PluginProjectSummary(
                        name: row["name"],
                        path: row["path"],
                        type: row["type"],
                        gitBranch: row["git_branch"],
                        gitDirty: (row["git_dirty"] as? Bool) ?? ((row["git_dirty"] as? Int64 ?? 0) != 0),
                        lastModified: row["last_modified"] as? Date ?? Date()
                    )
                }
            }
            guard !projects.isEmpty else {
                return textResult(id: id, text: "[]")
            }
            let iso = ISO8601DateFormatter()
            let items = projects.map { p in
                let branch = p.gitBranch.map { "\"\(esc($0))\"" } ?? "null"
                let dirty = p.gitDirty ? "true" : "false"
                return #"{"name":"\#(esc(p.name))","path":"\#(esc(p.path))","type":"\#(esc(p.type))","git_branch":\#(branch),"git_dirty":\#(dirty),"last_modified":"\#(iso.string(from: p.lastModified))"}"#
            }
            let payload = "[\(items.joined(separator: ","))]"
            return textResult(id: id, text: payload)
        } catch {
            wtLog("[PluginServer] toolListProjects error: \(error)")
            return mcpError(id: id, message: "Failed to list projects: \(error.localizedDescription)")
        }
    }

    private func toolListActiveJobs(id: String) async -> String {
        do {
            let jobs = try await DatabaseManager.shared.asyncRead { db in
                return try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, type, command, status, created_at
                        FROM canvas_jobs
                        WHERE status IN ('queued', 'running')
                        ORDER BY created_at DESC
                        """
                ).map { row in
                    PluginJobSummary(
                        id: row["id"],
                        type: row["type"],
                        command: row["command"],
                        status: row["status"],
                        createdAt: row["created_at"] as? Date ?? Date()
                    )
                }
            }
            guard !jobs.isEmpty else {
                return textResult(id: id, text: "[]")
            }
            let iso = ISO8601DateFormatter()
            let items = jobs.map { j in
                #"{"id":"\#(esc(j.id))","type":"\#(esc(j.type))","command":"\#(esc(j.command))","status":"\#(esc(j.status))","created_at":"\#(iso.string(from: j.createdAt))"}"#
            }
            let payload = "[\(items.joined(separator: ","))]"
            return textResult(id: id, text: payload)
        } catch {
            wtLog("[PluginServer] toolListActiveJobs error: \(error)")
            return mcpError(id: id, message: "Failed to list active jobs: \(error.localizedDescription)")
        }
    }

    private func toolGetJob(jobId: String, id: String) async -> String {
        let trimmedJobId = jobId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedJobId.isEmpty else {
            return mcpError(id: id, message: "job_id is required")
        }

        do {
            let job = try await DatabaseManager.shared.asyncRead { db in
                try WorldTreeJob.fetchOne(db, key: trimmedJobId)
            }
            guard let job else {
                return textResult(id: id, text: "null")
            }

            let iso = ISO8601DateFormatter()
            let outputLimit = 20_000
            let fullOutput = job.output ?? ""
            let outputWasTruncated = fullOutput.count > outputLimit
            let outputPreview = outputWasTruncated ? String(fullOutput.prefix(outputLimit)) : fullOutput
            let completedAt = job.completedAt.map { "\"\(iso.string(from: $0))\"" } ?? "null"
            let branchId = jsonStringOrNull(job.branchId)
            let output = outputPreview.isEmpty ? "null" : "\"\(esc(outputPreview))\""
            let errorText = jsonStringOrNull(job.error)

            let payload = """
            {"id":"\(esc(job.id))","type":"\(esc(job.type))","command":"\(esc(job.command))","working_directory":"\(esc(job.workingDirectory))","branch_id":\(branchId),"status":"\(esc(job.status.rawValue))","created_at":"\(iso.string(from: job.createdAt))","completed_at":\(completedAt),"output":\(output),"output_truncated":\(outputWasTruncated ? "true" : "false"),"error":\(errorText)}
            """
            .trimmingCharacters(in: .whitespacesAndNewlines)

            return textResult(id: id, text: payload)
        } catch {
            wtLog("[PluginServer] toolGetJob error: \(error)")
            return mcpError(id: id, message: "Failed to get job: \(error.localizedDescription)")
        }
    }

    private func toolLearnVideo(
        project: String?,
        workingDirectory: String?,
        mode: String,
        input: String?,
        visual: Bool,
        maxResults: Int?,
        id: String
    ) async -> String {
        do {
            let resolvedWorkingDirectory = try await resolveLearningWorkingDirectory(
                project: project,
                explicitWorkingDirectory: workingDirectory
            )
            guard FileManager.default.fileExists(atPath: resolvedWorkingDirectory) else {
                return mcpError(id: id, message: "Working directory does not exist: \(resolvedWorkingDirectory)")
            }

            let command = try buildLearnVideoCommand(
                mode: mode,
                input: input,
                visual: visual,
                maxResults: maxResults
            )
            let jobId = await JobQueue.shared.enqueue(
                command: command,
                workingDirectory: resolvedWorkingDirectory,
                type: "video_learning"
            )

            let trimmedProject = project?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedInput = input?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedMode = normalizedLearnVideoMode(mode)
            let payload = """
            {"job_id":"\(esc(jobId))","type":"video_learning","project":\(jsonStringOrNull(trimmedProject)),"working_directory":"\(esc(resolvedWorkingDirectory))","mode":"\(esc(normalizedMode))","input":\(jsonStringOrNull(trimmedInput)),"visual":\(visual ? "true" : "false"),"max_results":\(maxResults.map(String.init) ?? "null"),"output_path_hint":"\(esc(resolvedWorkingDirectory))/.claude/knowledge/video-learnings","notes":"Queued in World Tree JobQueue. Poll world_tree_get_job with the returned job_id for status and output."}
            """
            .trimmingCharacters(in: .whitespacesAndNewlines)

            return textResult(id: id, text: payload)
        } catch {
            wtLog("[PluginServer] toolLearnVideo error: \(error)")
            return mcpError(id: id, message: error.localizedDescription)
        }
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

    private func toolFrameScreenshot(frameId: String, id: String) async -> String {
        guard PencilConnectionStore.shared.isConnected else {
            return mcpError(id: id, message: "Pencil is not connected")
        }
        PencilConnectionStore.shared.invalidateScreenshotCache(for: frameId)
        do {
            let pngData = try await PencilConnectionStore.shared.getFrameScreenshot(frameId: frameId)
            let b64 = pngData.base64EncodedString()
            return imageResult(id: id, data: b64, mimeType: "image/png")
        } catch {
            wtLog("[PluginServer] toolFrameScreenshot error: \(error)")
            return mcpError(id: id, message: "Screenshot failed: \(error.localizedDescription)")
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

    private func sendResponse(
        _ connection: NWConnection,
        status: Int,
        body: String?,
        contentType: String? = "application/json"
    ) {
        let bodyBytes = body?.data(using: .utf8) ?? Data()
        var header = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        if let contentType {
            header += "Content-Type: \(contentType)\r\n"
        }
        header += "Content-Length: \(bodyBytes.count)\r\n" +
                  "Access-Control-Allow-Origin: http://localhost\r\n" +
                  "Connection: close\r\n\r\n"
        var resp = Data(header.utf8)
        resp.append(bodyBytes)
        connection.send(content: resp, completion: .contentProcessed { error in
            if let error {
                wtLog("[PluginServer] sendResponse error: \(error)")
            }
            connection.cancel()
        })
    }

    private func statusText(_ code: Int) -> String {
        [200: "OK", 202: "Accepted", 400: "Bad Request", 404: "Not Found",
         500: "Internal Server Error"][code] ?? "Unknown"
    }

    // MARK: - MCP Response Helpers

    /// Wraps a text payload as an MCP tools/call result.
    private func textResult(id: String, text: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"text","text":"\#(esc(text))"}]}}"#
    }

    /// Wraps a base64 image as an MCP image content block.
    private func imageResult(id: String, data: String, mimeType: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"image","data":"\#(data)","mimeType":"\#(mimeType)"}]}}"#
    }

    private func mcpError(id: String, message: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"\#(esc(message))"}}"#
    }

    // MARK: - String Escaping

    private func learnVideoExecutablePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cortana/bin/learn-video"
    }

    private func normalizedLearnVideoMode(_ mode: String) -> String {
        let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "video" : trimmed
    }

    private func buildLearnVideoCommand(
        mode: String,
        input: String?,
        visual: Bool,
        maxResults: Int?
    ) throws -> String {
        let executable = learnVideoExecutablePath()
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw NSError(
                domain: "PluginServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "learn-video is not available at \(executable)"]
            )
        }

        let normalizedMode = normalizedLearnVideoMode(mode)
        let trimmedInput = input?.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = [shellQuote(executable)]

        switch normalizedMode {
        case "video":
            guard let trimmedInput, !trimmedInput.isEmpty else {
                throw NSError(
                    domain: "PluginServer",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "input is required for video mode"]
                )
            }
            args.append(shellQuote(trimmedInput))
            if visual {
                args.append("--visual")
            }

        case "full":
            guard let trimmedInput, !trimmedInput.isEmpty else {
                throw NSError(
                    domain: "PluginServer",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "input is required for full mode"]
                )
            }
            args.append("full")
            args.append(shellQuote(trimmedInput))

        case "visual", "workflow", "search", "playlist":
            guard let trimmedInput, !trimmedInput.isEmpty else {
                throw NSError(
                    domain: "PluginServer",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "input is required for \(normalizedMode) mode"]
                )
            }
            args.append(normalizedMode)
            args.append(shellQuote(trimmedInput))
            if let maxResults, ["search", "playlist"].contains(normalizedMode) {
                args.append("-m")
                args.append(String(max(1, min(maxResults, 25))))
            }
            if visual && normalizedMode == "search" {
                args.append("--visual")
            }

        case "list", "status":
            args.append(normalizedMode)

        default:
            throw NSError(
                domain: "PluginServer",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported mode '\(mode)'. Use video, full, visual, workflow, search, playlist, list, or status."]
            )
        }

        let innerCommand = args.joined(separator: " ")
        return "/bin/zsh -lc \(shellQuote(innerCommand))"
    }

    private func resolveLearningWorkingDirectory(
        project: String?,
        explicitWorkingDirectory: String?
    ) async throws -> String {
        if let explicitWorkingDirectory {
            let trimmed = explicitWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let trimmedProject = project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedProject.isEmpty else {
            throw NSError(
                domain: "PluginServer",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Provide either project or working_directory."]
            )
        }

        let resolvedPath = try await DatabaseManager.shared.asyncRead { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT path
                    FROM project_cache
                    WHERE LOWER(name) = LOWER(?)
                    LIMIT 1
                    """,
                arguments: [trimmedProject]
            )
        }

        guard let resolvedPath, !resolvedPath.isEmpty else {
            throw NSError(
                domain: "PluginServer",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Project '\(trimmedProject)' was not found in World Tree project_cache."]
            )
        }

        return resolvedPath
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func jsonStringOrNull(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "null" }
        return "\"\(esc(value))\""
    }

    private func esc(_ s: String) -> String { escapeJSONString(s) }
}
