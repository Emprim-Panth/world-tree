import Foundation
import Network
import GRDB

/// Lightweight HTTP server on 127.0.0.1:port (default 4863).
/// Serves project context to Claude sessions via GET /context/:project.
/// All I/O runs on a private serial queue; state updates dispatch to main.
final class ContextServer {
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.forgeandcode.WorldTree.ContextServer")

    /// Maximum allowed HTTP body size (1 MB).
    private static let maxBodySize = 1_048_576

    /// Maximum concurrent connections.
    private static let maxConnections = 50

    /// Per-connection timeout in seconds.
    private static let connectionTimeout: TimeInterval = 30

    /// Active connection count, accessed only on `queue`.
    private var activeConnections = 0

    init(port: UInt16 = 4863) {
        self.port = port
    }

    // MARK: — Lifecycle

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: port)!
            )
            listener = try NWListener(using: params)
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    wtLog("[ContextServer] listening on 127.0.0.1:\(self.port)")
                    Task { @MainActor in
                        AppState.shared.contextServerReachable = true
                    }
                case .failed(let err):
                    wtLog("[ContextServer] failed: \(err)")
                    Task { @MainActor in
                        AppState.shared.contextServerReachable = false
                    }
                default:
                    break
                }
            }
            listener?.start(queue: queue)
        } catch {
            wtLog("[ContextServer] start error: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        Task { @MainActor in
            AppState.shared.contextServerReachable = false
        }
    }

    // MARK: — Connection

    private func handleConnection(_ conn: NWConnection) {
        // Fix 3: Reject if at connection limit
        guard activeConnections < Self.maxConnections else {
            conn.start(queue: queue)
            send(conn, status: 503, json: #"{"error":"too many connections"}"#)
            return
        }
        activeConnections += 1

        conn.start(queue: queue)

        // Fix 2: Schedule a 30-second deadline for this connection
        let deadline = DispatchWorkItem { [weak self] in
            wtLog("[ContextServer] connection timed out")
            conn.cancel()
            self?.decrementConnections()
        }
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout, execute: deadline)

        readRequest(conn, deadline: deadline)
    }

    private func decrementConnections() {
        // Must be called on `queue`
        activeConnections = max(0, activeConnections - 1)
    }

    private func readRequest(_ conn: NWConnection, deadline: DispatchWorkItem) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                deadline.cancel()
                self?.decrementConnections()
                conn.cancel()
                return
            }

            let raw = String(data: data, encoding: .utf8) ?? ""
            let (method, path) = self.parseRequestLine(raw)

            // Fix 1: Parse Content-Length and continue reading if body is incomplete
            let contentLength = self.parseContentLength(raw)
            let partialBody = self.extractBody(raw)

            if contentLength > Self.maxBodySize {
                deadline.cancel()
                self.decrementConnections()
                self.send(conn, status: 413, json: #"{"error":"body too large"}"#)
                return
            }

            let remaining = contentLength - partialBody.utf8.count
            if remaining > 0 {
                self.readRemainingBody(conn, existing: partialBody, remaining: remaining, method: method, path: path, deadline: deadline)
            } else {
                deadline.cancel()
                self.decrementConnections()
                self.route(method: method, path: path, body: partialBody, conn: conn)
            }
        }
    }

    /// Continue reading until the full Content-Length body is received.
    private func readRemainingBody(_ conn: NWConnection, existing: String, remaining: Int, method: String, path: String, deadline: DispatchWorkItem) {
        let toRead = min(remaining, 65536)
        conn.receive(minimumIncompleteLength: 1, maximumLength: toRead) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, !data.isEmpty else {
                deadline.cancel()
                self.decrementConnections()
                conn.cancel()
                return
            }

            let chunk = String(data: data, encoding: .utf8) ?? ""
            let accumulated = existing + chunk
            let newRemaining = remaining - data.count

            if accumulated.utf8.count > Self.maxBodySize {
                deadline.cancel()
                self.decrementConnections()
                self.send(conn, status: 413, json: #"{"error":"body too large"}"#)
                return
            }

            if newRemaining > 0 {
                self.readRemainingBody(conn, existing: accumulated, remaining: newRemaining, method: method, path: path, deadline: deadline)
            } else {
                deadline.cancel()
                self.decrementConnections()
                self.route(method: method, path: path, body: accumulated, conn: conn)
            }
        }
    }

    // MARK: — Routing

    private func route(method: String, path: String, body: String, conn: NWConnection) {
        let pathOnly = path.components(separatedBy: "?").first ?? path
        let segments = pathOnly.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        switch (method, segments.first, segments.dropFirst().first) {

        case ("GET", "health", nil):
            send(conn, status: 200, json: #"{"status":"ok"}"#)

        case ("GET", "context", let project?):
            handleGetContext(project: project, conn: conn)

        case ("POST", "brain", let project?):
            if segments.count == 3, segments[2] == "update" {
                handleBrainUpdate(project: project, body: body, conn: conn)
            } else {
                send(conn, status: 404, json: #"{"error":"not found"}"#)
            }

        case ("POST", "session", "summary"):
            handleSessionSummary(body: body, conn: conn)

        case ("GET", "brain", let second?) where second == "search":
            handleBrainSearch(path: path, conn: conn)

        case ("GET", "intelligence", let second?) where second == "status":
            handleIntelligenceStatus(conn: conn)

        case ("POST", "inference", "log"):
            handlePostInferenceLog(body: body, conn: conn)

        case ("GET", "inference", "recent"):
            handleGetRecentInference(path: path, conn: conn)

        case ("GET", "agent", "active"):
            handleGetAgentActive(conn: conn)

        case ("GET", "agent", "sessions"):
            handleGetAgentSessions(conn: conn)

        case ("POST", "agent", let sessionId?) where segments.count == 4 && segments[3] == "proof":
            handlePostAgentProof(sessionId: sessionId, body: body, conn: conn)

        case ("GET", "agent", let sessionId?) where segments.count == 4 && segments[3] == "proof":
            handleGetAgentProof(sessionId: sessionId, conn: conn)

        case ("POST", "agent", let sessionId?) where segments.count == 4 && segments[3] == "screenshot":
            handlePostAgentScreenshot(sessionId: sessionId, body: body, conn: conn)

        case ("GET", "agent", let sessionId?) where segments.count >= 4 && segments[3] == "screenshot":
            handleGetAgentScreenshotLatest(sessionId: sessionId, conn: conn)

        // Fix 4: Compass, Ticket, and Alert API endpoints
        case ("GET", "compass", "overview"):
            handleGetCompassOverview(conn: conn)

        case ("GET", "compass", let project?):
            handleGetCompassProject(project: project, conn: conn)

        case ("GET", "tickets", let project?):
            handleGetTickets(project: project, conn: conn)

        case ("POST", "alerts", nil):
            handlePostAlert(body: body, conn: conn)

        case ("PATCH", "alerts", let alertId?):
            handlePatchAlertResolve(alertId: alertId, conn: conn)

        default:
            send(conn, status: 404, json: #"{"error":"not found"}"#)
        }
    }

    // MARK: — Handlers

    private func handleGetContext(project: String, conn: NWConnection) {
        Task { @MainActor in
            let brain = BrainFileStore.shared.read(project: project) ?? ""
            let compass = CompassStore.shared.states[project]

            var parts: [String] = []

            if let cs = compass {
                var meta = "# \(project)"
                if let phase = cs.currentPhase { meta += "\nPhase: \(phase)" }
                if let goal = cs.currentGoal { meta += "\nGoal: \(goal)" }
                if let branch = cs.gitBranch { meta += "\nBranch: \(branch)" }
                if cs.isDirty { meta += " (\(cs.gitUncommittedCount) uncommitted)" }
                if !cs.blockers.isEmpty { meta += "\nBlockers: \(cs.blockers.joined(separator: ", "))" }
                parts.append(meta)
            }

            if !brain.isEmpty {
                // Truncate to ~1400 tokens (~5600 chars) to stay under context budget
                let truncated = brain.count > 5600 ? String(brain.prefix(5600)) + "\n…[truncated]" : brain
                parts.append(truncated)
            }

            let context = parts.joined(separator: "\n\n---\n\n")
            let escaped = escapeJSONString(context)
            let response = #"{"project":"\#(escapeJSONString(project))","context":"\#(escaped)"}"#
            self.send(conn, status: 200, json: response)
        }
    }

    private func handleBrainUpdate(project: String, body: String, conn: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? String else {
            send(conn, status: 400, json: #"{"error":"missing content field"}"#)
            return
        }
        Task { @MainActor in
            do {
                try BrainFileStore.shared.write(content, for: project)
                self.send(conn, status: 200, json: #"{"ok":true}"#)
            } catch {
                self.send(conn, status: 500, json: #"{"error":"\#(escapeJSONString(error.localizedDescription))"}"#)
            }
        }
    }

    private func handleSessionSummary(body: String, conn: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let project = json["project"] as? String,
              let summary = json["summary"] as? String else {
            send(conn, status: 400, json: #"{"error":"missing project or summary"}"#)
            return
        }
        Task { @MainActor in
            CompassStore.shared.updateLastSessionSummary(summary, for: project)
            self.send(conn, status: 200, json: #"{"ok":true}"#)
        }
    }

    // MARK: — Brain Search & Intelligence

    private func handleBrainSearch(path: String, conn: NWConnection) {
        // Parse query params from path: /brain/search?q=...&limit=...
        let components = URLComponents(string: "http://localhost\(path)")
        let query = components?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
        let limit = Int(components?.queryItems?.first(where: { $0.name == "limit" })?.value ?? "10") ?? 10

        guard !query.isEmpty else {
            send(conn, status: 400, json: #"{"error":"missing q parameter"}"#)
            return
        }

        Task { @MainActor in
            let results = await BrainIndexer.shared.search(query: query, limit: limit)
            let items = results.map { r in
                #"{"file":"\#(escapeJSONString(r.filePath))","chunk":"\#(escapeJSONString(String(r.content.prefix(500))))","score":\#(String(format: "%.3f", r.score)),"match_type":"\#(r.matchType)"}"#
            }
            let json = #"{"query":"\#(escapeJSONString(query))","results":[\#(items.joined(separator: ","))]}"#
            self.send(conn, status: 200, json: json)
        }
    }

    private func handleIntelligenceStatus(conn: NWConnection) {
        Task { @MainActor in
            let router = QualityRouter.shared
            let indexer = BrainIndexer.shared
            let models = await router.loadedModels()

            let modelJSON = models.map { m in
                #"{"name":"\#(escapeJSONString(m.name))","size":"\#(m.size)","loaded":\#(m.isLoaded)}"#
            }.joined(separator: ",")

            let stats = router.todayStats
            let json = """
            {"models":[\(modelJSON)],"routing":{"local":\(stats.localCount),"claude":\(stats.claudeCount),"local_percent":\(stats.localPercent)},"brain_index":{"chunks":\(indexer.chunkCount),"indexing":\(indexer.isIndexing),"last_index":"\(indexer.lastIndexDate.map { ISO8601DateFormatter().string(from: $0) } ?? "never")"}}
            """
            self.send(conn, status: 200, json: json)
        }
    }

    // MARK: — Inference Log Handlers

    private func handlePostInferenceLog(body: String, conn: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let taskType = json["task_type"] as? String,
              let provider = json["provider"] as? String else {
            send(conn, status: 400, json: #"{"error":"missing task_type or provider"}"#)
            return
        }

        let inputTokens = json["input_tokens"] as? Int ?? 0
        let outputTokens = json["output_tokens"] as? Int ?? 0
        let latencyMs = json["latency_ms"] as? Int ?? 0
        let confidence = json["confidence"] as? String
        let escalated = json["escalated"] as? Bool ?? false
        let escalationReason = json["escalation_reason"] as? String

        Task { @MainActor in
            do {
                try DatabaseManager.shared.write { db in
                    try db.execute(sql: """
                        INSERT INTO inference_log
                            (task_type, provider, input_tokens, output_tokens, latency_ms,
                             confidence, escalated, escalation_reason, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
                    """, arguments: [
                        taskType, provider, inputTokens, outputTokens, latencyMs,
                        confidence, escalated ? 1 : 0, escalationReason
                    ])
                }
                self.send(conn, status: 200, json: #"{"status":"logged"}"#)
            } catch {
                self.send(conn, status: 500, json: #"{"error":"\#(escapeJSONString(error.localizedDescription))"}"#)
            }
        }
    }

    private func handleGetRecentInference(path: String, conn: NWConnection) {
        let components = URLComponents(string: "http://localhost\(path)")
        let limit = Int(components?.queryItems?.first(where: { $0.name == "limit" })?.value ?? "20") ?? 20

        Task { @MainActor in
            do {
                let rows = try DatabaseManager.shared.read { db in
                    guard try db.tableExists("inference_log") else { return [Row]() }
                    return try Row.fetchAll(db, sql: """
                        SELECT task_type, provider, input_tokens, output_tokens,
                               latency_ms, confidence, escalated, escalation_reason, created_at
                        FROM inference_log
                        ORDER BY created_at DESC
                        LIMIT ?
                    """, arguments: [limit])
                }

                let items = rows.map { row -> String in
                    let taskType: String = row["task_type"] ?? ""
                    let provider: String = row["provider"] ?? ""
                    let inputTokens: Int = row["input_tokens"] ?? 0
                    let outputTokens: Int = row["output_tokens"] ?? 0
                    let latency: Int = row["latency_ms"] ?? 0
                    let confidence: String = row["confidence"] ?? ""
                    let escalated: Int = row["escalated"] ?? 0
                    let createdAt: String = row["created_at"] ?? ""
                    return #"{"task_type":"\#(escapeJSONString(taskType))","provider":"\#(escapeJSONString(provider))","input_tokens":\#(inputTokens),"output_tokens":\#(outputTokens),"latency_ms":\#(latency),"confidence":"\#(escapeJSONString(confidence))","escalated":\#(escalated == 1),"created_at":"\#(escapeJSONString(createdAt))"}"#
                }

                self.send(conn, status: 200, json: #"{"entries":[\#(items.joined(separator: ","))]}"#)
            } catch {
                self.send(conn, status: 500, json: #"{"error":"\#(escapeJSONString(error.localizedDescription))"}"#)
            }
        }
    }

    // MARK: — Compass & Ticket Handlers

    private func handleGetCompassProject(project: String, conn: NWConnection) {
        Task { @MainActor in
            guard let state = CompassStore.shared.states[project] else {
                self.send(conn, status: 404, json: #"{"error":"project not found"}"#)
                return
            }
            do {
                let data = try JSONEncoder().encode(state)
                let json = String(data: data, encoding: .utf8) ?? "{}"
                self.send(conn, status: 200, json: json)
            } catch {
                self.send(conn, status: 500, json: #"{"error":"\#(escapeJSONString(error.localizedDescription))"}"#)
            }
        }
    }

    private func handleGetCompassOverview(conn: NWConnection) {
        Task { @MainActor in
            let allStates = Array(CompassStore.shared.states.values)
            do {
                let data = try JSONEncoder().encode(allStates)
                let json = String(data: data, encoding: .utf8) ?? "[]"
                self.send(conn, status: 200, json: json)
            } catch {
                self.send(conn, status: 500, json: #"{"error":"\#(escapeJSONString(error.localizedDescription))"}"#)
            }
        }
    }

    private func handleGetTickets(project: String, conn: NWConnection) {
        Task { @MainActor in
            let tickets = TicketStore.shared.tickets(for: project)
            do {
                let data = try JSONEncoder().encode(tickets)
                let json = String(data: data, encoding: .utf8) ?? "[]"
                self.send(conn, status: 200, json: json)
            } catch {
                self.send(conn, status: 500, json: #"{"error":"\#(escapeJSONString(error.localizedDescription))"}"#)
            }
        }
    }

    private func handlePostAlert(body: String, conn: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              let message = json["message"] as? String else {
            send(conn, status: 400, json: #"{"error":"missing type or message"}"#)
            return
        }

        let id = json["id"] as? String ?? UUID().uuidString
        let project = json["project"] as? String
        let severity = json["severity"] as? String ?? "info"
        let source = json["source"] as? String ?? "api"

        Task { @MainActor in
            do {
                try DatabaseManager.shared.write { db in
                    try db.execute(sql: """
                        INSERT INTO cortana_alerts (id, type, project, message, severity, source, resolved, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, 0, datetime('now'))
                    """, arguments: [id, type, project, message, severity, source])
                }
                self.send(conn, status: 200, json: #"{"ok":true,"id":"\#(escapeJSONString(id))"}"#)
            } catch {
                self.send(conn, status: 500, json: #"{"error":"\#(escapeJSONString(error.localizedDescription))"}"#)
            }
        }
    }

    private func handlePatchAlertResolve(alertId: String, conn: NWConnection) {
        Task { @MainActor in
            do {
                try DatabaseManager.shared.write { db in
                    try db.execute(
                        sql: "UPDATE cortana_alerts SET resolved = 1, resolved_at = datetime('now') WHERE id = ?",
                        arguments: [alertId]
                    )
                }
                self.send(conn, status: 200, json: #"{"ok":true}"#)
            } catch {
                self.send(conn, status: 500, json: #"{"error":"\#(escapeJSONString(error.localizedDescription))"}"#)
            }
        }
    }

    // MARK: — Agent Handlers

    private func handleGetAgentActive(conn: NWConnection) {
        Task { @MainActor in
            do {
                let row = try DatabaseManager.shared.read { db in
                    try Row.fetchOne(db, sql: """
                        SELECT id, project,
                               COALESCE(task, current_task) AS task,
                               started_at, completed_at,
                               COALESCE(build_status, exit_reason) AS build_status,
                               proof_path
                        FROM agent_sessions
                        WHERE completed_at IS NULL
                          AND (status IS NULL OR status NOT IN ('completed','failed','interrupted'))
                        ORDER BY started_at DESC LIMIT 1
                        """)
                }
                if let row = row {
                    let json = self.agentSessionRowToJSON(row)
                    self.send(conn, status: 200, json: json)
                } else {
                    self.send(conn, status: 200, json: #"{"active":null}"#)
                }
            } catch {
                self.send(conn, status: 500, json: #"{"error":"db error"}"#)
            }
        }
    }

    private func handleGetAgentSessions(conn: NWConnection) {
        Task { @MainActor in
            do {
                let rows = try DatabaseManager.shared.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT id, project,
                               COALESCE(task, current_task) AS task,
                               started_at, completed_at,
                               COALESCE(build_status, exit_reason) AS build_status,
                               proof_path
                        FROM agent_sessions
                        ORDER BY started_at DESC LIMIT 30
                        """)
                }
                let items = rows.map { self.agentSessionRowToJSON($0) }
                let json = "[\(items.joined(separator: ","))]"
                self.send(conn, status: 200, json: json)
            } catch {
                self.send(conn, status: 500, json: #"{"error":"db error"}"#)
            }
        }
    }

    private func handlePostAgentProof(sessionId: String, body: String, conn: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            send(conn, status: 400, json: #"{"error":"invalid json"}"#)
            return
        }
        let proofPath = json["proof_path"] as? String ?? ""
        let completedAt = json["completed_at"] as? String ?? ISO8601DateFormatter().string(from: Date())
        let buildStatus = json["build_status"] as? String ?? "unknown"
        let project = json["project"] as? String ?? ""
        let task = json["task"] as? String ?? ""
        let startedAt = json["started_at"] as? String ?? completedAt

        Task { @MainActor in
            do {
                try DatabaseManager.shared.write { db in
                    try db.execute(sql: """
                        INSERT INTO agent_sessions (id, project, task, started_at, completed_at, build_status, proof_path)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            completed_at = excluded.completed_at,
                            build_status = excluded.build_status,
                            proof_path = excluded.proof_path
                        """, arguments: [sessionId, project, task, startedAt, completedAt, buildStatus, proofPath])
                }
                self.send(conn, status: 200, json: #"{"ok":true}"#)
            } catch {
                self.send(conn, status: 500, json: #"{"error":"db write failed"}"#)
            }
        }
    }

    private func handleGetAgentProof(sessionId: String, conn: NWConnection) {
        Task { @MainActor in
            do {
                let row = try DatabaseManager.shared.read { db in
                    try Row.fetchOne(db, sql: "SELECT proof_path FROM agent_sessions WHERE id = ?", arguments: [sessionId])
                }
                guard let proofPath = row?["proof_path"] as? String, !proofPath.isEmpty else {
                    self.send(conn, status: 404, json: #"{"error":"not found"}"#)
                    return
                }
                guard let proofData = try? Data(contentsOf: URL(fileURLWithPath: proofPath)),
                      let proofJSON = String(data: proofData, encoding: .utf8) else {
                    self.send(conn, status: 404, json: #"{"error":"proof file not readable"}"#)
                    return
                }
                // Return the proof file contents as-is (it's already JSON)
                self.send(conn, status: 200, json: proofJSON)
            } catch {
                self.send(conn, status: 500, json: #"{"error":"db error"}"#)
            }
        }
    }

    private func handlePostAgentScreenshot(sessionId: String, body: String, conn: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["path"] as? String else {
            send(conn, status: 400, json: #"{"error":"missing path"}"#)
            return
        }
        let capturedAt = json["capturedAt"] as? String ?? ISO8601DateFormatter().string(from: Date())
        let context = json["context"] as? String ?? ""
        let project = json["project"] as? String ?? ""
        let screenshotId = UUID().uuidString

        Task { @MainActor in
            do {
                try DatabaseManager.shared.write { db in
                    // Upsert session record if not already present
                    try db.execute(sql: """
                        INSERT INTO agent_sessions (id, project, task, started_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(id) DO NOTHING
                        """, arguments: [sessionId, project, nil as String?, capturedAt])
                    // Insert screenshot record
                    try db.execute(sql: """
                        INSERT INTO agent_screenshots (id, session_id, path, captured_at, context)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: [screenshotId, sessionId, path, capturedAt, context])
                }
                self.send(conn, status: 200, json: #"{"ok":true}"#)
            } catch {
                self.send(conn, status: 500, json: #"{"error":"db write failed"}"#)
            }
        }
    }

    private func handleGetAgentScreenshotLatest(sessionId: String, conn: NWConnection) {
        Task { @MainActor in
            do {
                let row = try DatabaseManager.shared.read { db in
                    try Row.fetchOne(db, sql: """
                        SELECT path FROM agent_screenshots
                        WHERE session_id = ?
                        ORDER BY captured_at DESC LIMIT 1
                        """, arguments: [sessionId])
                }
                guard let path = row?["path"] as? String, !path.isEmpty else {
                    self.send(conn, status: 404, json: #"{"error":"no screenshot"}"#)
                    return
                }
                guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                    self.send(conn, status: 404, json: #"{"error":"screenshot file not readable"}"#)
                    return
                }
                let header = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(imageData.count)\r\nConnection: close\r\n\r\n"
                var response = header.data(using: .utf8)!
                response.append(imageData)
                conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
            } catch {
                self.send(conn, status: 500, json: #"{"error":"db error"}"#)
            }
        }
    }

    // MARK: — Agent JSON Helpers

    private func agentSessionRowToJSON(_ row: Row) -> String {
        let id = row["id"] as? String ?? ""
        let project = row["project"] as? String ?? ""
        let task = row["task"] as? String
        let startedAt = row["started_at"] as? String
        let completedAt = row["completed_at"] as? String
        let buildStatus = row["build_status"] as? String
        let proofPath = row["proof_path"] as? String

        let taskJSON = task.map { #""\#(escapeJSONString($0))""# } ?? "null"
        let startedAtJSON = startedAt.map { #""\#(escapeJSONString($0))""# } ?? "null"
        let completedAtJSON = completedAt.map { #""\#(escapeJSONString($0))""# } ?? "null"
        let buildStatusJSON = buildStatus.map { #""\#(escapeJSONString($0))""# } ?? "null"
        let proofPathJSON = proofPath.map { #""\#(escapeJSONString($0))""# } ?? "null"

        return """
        {"id":"\(escapeJSONString(id))","project":"\(escapeJSONString(project))","task":\(taskJSON),"startedAt":\(startedAtJSON),"completedAt":\(completedAtJSON),"buildStatus":\(buildStatusJSON),"proofPath":\(proofPathJSON)}
        """
    }

    // MARK: — HTTP Helpers

    private func send(_ conn: NWConnection, status: Int, json: String) {
        let body = json.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status) \(statusText(status))\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = header.data(using: .utf8)!
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 413: "Payload Too Large"
        case 503: "Service Unavailable"
        case 500: "Internal Server Error"
        default: "Unknown"
        }
    }

    private func parseRequestLine(_ raw: String) -> (String, String) {
        let lines = raw.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").components(separatedBy: " ")
        guard parts.count >= 2 else { return ("GET", "/") }
        return (parts[0], parts[1])
    }

    private func extractBody(_ raw: String) -> String {
        guard let range = raw.range(of: "\r\n\r\n") else { return "" }
        return String(raw[range.upperBound...])
    }

    /// Parse Content-Length from HTTP headers. Returns 0 if absent.
    private func parseContentLength(_ raw: String) -> Int {
        let lines = raw.components(separatedBy: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }
}
