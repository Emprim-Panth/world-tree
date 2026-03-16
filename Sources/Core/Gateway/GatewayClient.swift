import Foundation

/// HTTP client for connecting Canvas to the Ark Gateway
actor GatewayClient {
    private let baseURL: URL
    private let authToken: String
    private let session: URLSession

    /// Default gateway URL — extracted as a constant so the fallback never force-unwraps.
    private static let defaultURL = URL(string: "http://localhost:4862")!  // swiftlint:disable:this force_unwrapping — compile-time constant, always valid

    init(baseURL: String = "http://localhost:4862", authToken: String) {
        // Fall back to default if a misconfigured URL is passed — prevents crash on bad input
        self.baseURL = URL(string: baseURL) ?? Self.defaultURL
        self.authToken = authToken

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15    // 15s between data packets
        config.timeoutIntervalForResource = 60   // 60s total per request
        self.session = URLSession(configuration: config)
    }

    static func fromLocalConfig() -> GatewayClient? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.cortana/ark-gateway.toml"

        guard let configData = FileManager.default.contents(atPath: configPath),
              let configStr = String(data: configData, encoding: .utf8),
              let token = extractTOMLValue(key: "auth_token", from: configStr) else {
            return nil
        }

        return GatewayClient(authToken: token)
    }

    // MARK: - Memory Operations

    func logMemory(
        category: String,
        content: String,
        project: String?,
        tags: [String]? = nil
    ) async throws -> Int64 {
        let endpoint = baseURL.appendingPathComponent("v1/cortana/memory/log")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

        let payload = MemoryLogRequest(
            note: content,
            tags: tags,
            category: category,
            project: project
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GatewayError.requestFailed
        }

        let result = try JSONDecoder().decode(MemoryLogResponse.self, from: data)
        return result.id
    }

    func searchMemory(
        query: String,
        project: String? = nil,
        category: String? = nil,
        limit: Int = 50
    ) async throws -> [KnowledgeEntry] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/cortana/memory/search"),
            resolvingAgainstBaseURL: false
        ) else { throw GatewayError.requestFailed }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        if let project = project {
            queryItems.append(URLQueryItem(name: "project", value: project))
        }

        if let category = category {
            queryItems.append(URLQueryItem(name: "category", value: category))
        }

        components.queryItems = queryItems

        guard let url = components.url else { throw GatewayError.requestFailed }
        var request = URLRequest(url: url)
        request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GatewayError.requestFailed
        }

        let entries = try JSONDecoder().decode([KnowledgeEntry].self, from: data)
        return entries
    }

    // MARK: - Handoff Operations

    func checkHandoffs(project: String? = nil) async throws -> [Handoff] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/cortana/handoffs"),
            resolvingAgainstBaseURL: false
        ) else { throw GatewayError.requestFailed }

        if let project = project {
            components.queryItems = [URLQueryItem(name: "project", value: project)]
        }

        guard let url = components.url else { throw GatewayError.requestFailed }
        var request = URLRequest(url: url)
        request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GatewayError.requestFailed
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let handoffs = try decoder.decode([Handoff].self, from: data)
        return handoffs
    }

    func createHandoff(
        message: String,
        project: String?,
        priority: String = "normal"
    ) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("v1/cortana/handoffs")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

        let payload = HandoffCreateRequest(
            message: message,
            project: project,
            priority: priority
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GatewayError.requestFailed
        }

        let result = try JSONDecoder().decode(HandoffCreateResponse.self, from: data)
        return result.id
    }

    func updateHandoff(id: String, status: String) async throws {
        let endpoint = baseURL.appendingPathComponent("v1/cortana/handoffs/\(id)/status")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

        let payload = ["status": status]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GatewayError.requestFailed
        }
    }

    // MARK: - Operational Watch State

    func listAgentEvents(
        project: String? = nil,
        source: String? = nil
    ) async throws -> [CortanaAgentEvent] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/cortana/events/agent"),
            resolvingAgainstBaseURL: false
        ) else { throw GatewayError.requestFailed }

        var items: [URLQueryItem] = []
        if let project {
            items.append(URLQueryItem(name: "project", value: project))
        }
        if let source {
            items.append(URLQueryItem(name: "source", value: source))
        }
        if !items.isEmpty {
            components.queryItems = items
        }

        guard let url = components.url else { throw GatewayError.requestFailed }
        var request = URLRequest(url: url)
        request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GatewayError.requestFailed
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([CortanaAgentEvent].self, from: data)
    }

    func listAttentionQueue(project: String? = nil) async throws -> [CortanaAttentionItem] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/cortana/attention/queue"),
            resolvingAgainstBaseURL: false
        ) else { throw GatewayError.requestFailed }

        if let project {
            components.queryItems = [URLQueryItem(name: "project", value: project)]
        }

        guard let url = components.url else { throw GatewayError.requestFailed }
        var request = URLRequest(url: url)
        request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GatewayError.requestFailed
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([CortanaAttentionItem].self, from: data)
    }

    func resolveAgentEvent(id: String, executedAction: String? = nil) async throws {
        let endpoint = baseURL.appendingPathComponent("v1/cortana/events/agent/\(id)/resolve")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

        let payload = ["executed_action": executedAction]
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GatewayError.requestFailed
        }
    }

    func updateAttentionItem(id: String, status: String) async throws {
        let endpoint = baseURL.appendingPathComponent("v1/cortana/attention/queue/\(id)/status")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

        let payload = ["status": status]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GatewayError.requestFailed
        }
    }

    // MARK: - Helpers

    private static func extractTOMLValue(key: String, from toml: String) -> String? {
        for line in toml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\(key)") {
                guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
                let valueStr = trimmed[trimmed.index(after: eqIdx)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if valueStr.hasPrefix("\""), valueStr.hasSuffix("\""), valueStr.count >= 2 {
                    return String(valueStr.dropFirst().dropLast())
                }
                return valueStr
            }
        }
        return nil
    }

    // MARK: - Terminal Operations

    func createTerminal(
        command: String = "bash",
        args: [String]? = nil,
        cwd: String? = nil,
        project: String? = nil,
        name: String? = nil
    ) async throws -> TerminalSession {
        let endpoint = baseURL.appendingPathComponent("v1/cortana/terminal/start")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

        let payload: [String: Any] = [
            "cmd": command,
            "args": args ?? [],
            "cwd": cwd as Any,
            "project": project as Any,
            "name": name as Any
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GatewayError.requestFailed
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TerminalSession.self, from: data)
    }

    func listTerminals() async throws -> [TerminalSession] {
        let endpoint = baseURL.appendingPathComponent("v1/cortana/terminal/list")
        var request = URLRequest(url: endpoint)
        request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GatewayError.requestFailed
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([TerminalSession].self, from: data)
    }

    func killTerminal(sessionId: String) async throws {
        let endpoint = baseURL.appendingPathComponent("v1/cortana/terminal/\(sessionId)/kill")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GatewayError.requestFailed
        }
    }

    /// Subscribe to terminal output with error classification.
    ///
    /// - Transient errors (timeouts, 503, network blips) retry with exponential backoff up to 10 times.
    /// - Permanent errors (401, 404, connection refused) retry up to 3 times then yield `.error` and stop.
    nonisolated func subscribeToTerminal(sessionId: String) -> AsyncStream<TerminalStreamEvent> {
        AsyncStream { continuation in
            Task {
                var transientRetries = 0
                var permanentRetries = 0
                let maxTransientRetries = 10
                let maxPermanentRetries = 3

                while !Task.isCancelled {
                    let url = baseURL.appendingPathComponent("v1/cortana/terminal/\(sessionId)/stream")
                    var request = URLRequest(url: url)
                    request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

                    do {
                        let (bytes, response) = try await session.bytes(for: request)

                        // Check HTTP status before reading the stream
                        if let httpResponse = response as? HTTPURLResponse,
                           !(200...299).contains(httpResponse.statusCode) {
                            let classified = Self.classifyHTTPError(statusCode: httpResponse.statusCode)
                            if classified.isPermanent {
                                permanentRetries += 1
                                if permanentRetries >= maxPermanentRetries {
                                    continuation.yield(.error(classified))
                                    break
                                }
                            } else {
                                transientRetries += 1
                                if transientRetries >= maxTransientRetries {
                                    continuation.yield(.error(.subscriptionFailed(underlying: "Max transient retries exceeded")))
                                    break
                                }
                            }
                            let delay = Self.backoffDelay(retry: transientRetries + permanentRetries)
                            try? await Task.sleep(nanoseconds: delay)
                            continue
                        }

                        // Connected successfully — reset transient counter
                        transientRetries = 0
                        permanentRetries = 0

                        for try await line in bytes.lines {
                            continuation.yield(.output(line))
                        }
                        // Stream ended normally (server closed) — stop reconnecting
                        break
                    } catch let urlError as URLError {
                        let classified = Self.classifyURLError(urlError)
                        if classified.isPermanent {
                            permanentRetries += 1
                            if permanentRetries >= maxPermanentRetries {
                                continuation.yield(.error(classified))
                                break
                            }
                        } else {
                            transientRetries += 1
                            if transientRetries >= maxTransientRetries {
                                continuation.yield(.error(.subscriptionFailed(underlying: urlError.localizedDescription)))
                                break
                            }
                        }
                        let delay = Self.backoffDelay(retry: transientRetries + permanentRetries)
                        try? await Task.sleep(nanoseconds: delay)
                    } catch {
                        // Unknown error — treat as transient
                        transientRetries += 1
                        if transientRetries >= maxTransientRetries {
                            continuation.yield(.error(.subscriptionFailed(underlying: error.localizedDescription)))
                            break
                        }
                        let delay = Self.backoffDelay(retry: transientRetries)
                        try? await Task.sleep(nanoseconds: delay)
                    }
                }

                continuation.finish()
            }
        }
    }

    // MARK: - Error Classification (Private)

    /// Classify an HTTP status code into a typed gateway error.
    private static func classifyHTTPError(statusCode: Int) -> GatewayError {
        switch statusCode {
        case 401, 403:
            return .unauthorized
        case 404:
            return .terminalNotFound
        case 400...499:
            return .permanentHTTPError(statusCode: statusCode)
        default:
            // 5xx and anything else — transient
            return .requestFailed
        }
    }

    /// Classify a URLError into a typed gateway error.
    private static func classifyURLError(_ error: URLError) -> GatewayError {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return .connectionRefused
        case .userAuthenticationRequired:
            return .unauthorized
        case .timedOut, .networkConnectionLost, .notConnectedToInternet:
            // Transient — network will likely recover
            return .requestFailed
        default:
            return .requestFailed
        }
    }

    /// Exponential backoff: 1s, 2s, 4s, 8s… capped at 30s.
    private static func backoffDelay(retry: Int) -> UInt64 {
        min(UInt64(pow(2.0, Double(max(0, retry - 1)))) * 1_000_000_000, 30_000_000_000)
    }

    func sendTerminalCommand(sessionId: String, command: String) async throws {
        let endpoint = baseURL.appendingPathComponent("v1/cortana/terminal/\(sessionId)/input")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

        let payload = ["data": command]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GatewayError.requestFailed
        }
    }
}

// MARK: - Terminal Models

struct TerminalSession: Codable, Identifiable {
    let id: String
    let cmd: String
    let args: [String]?
    let cwd: String?
    let project: String?
    let name: String?
    let pid: Int?
    let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, cmd, args, cwd, project, name, pid
        case createdAt = "created_at"
    }
}

// MARK: - Models

struct MemoryLogRequest: Codable {
    let note: String
    let tags: [String]?
    let category: String
    let project: String?
}

struct MemoryLogResponse: Codable {
    let id: Int64
    let ok: Bool
}

struct KnowledgeEntry: Codable, Identifiable {
    let id: Int64
    let category: String
    let content: String
    let project: String?
    let tags: [String]?
    let metadata: [String: AnyCodable]?
    let createdAt: Int64
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case id, category, content, project, tags, metadata
        case createdAt = "created_at"
        case sessionId = "session_id"
    }
}

struct Handoff: Codable, Identifiable {
    let id: String
    let message: String
    let project: String?
    let priority: String
    let status: String
    let source: String?
    let createdAt: Int64
    let pickedUpAt: Int64?
    let completedAt: Int64?
    let viewedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id, message, project, priority, status, source
        case createdAt = "created_at"
        case pickedUpAt = "picked_up_at"
        case completedAt = "completed_at"
        case viewedAt = "viewed_at"
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case createdAt
        case pickedUpAt
        case completedAt
        case viewedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        message = try container.decode(String.self, forKey: .message)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        priority = try container.decode(String.self, forKey: .priority)
        status = try container.decode(String.self, forKey: .status)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        createdAt = try container.decodeIfPresent(Int64.self, forKey: .createdAt)
            ?? legacy.decode(Int64.self, forKey: .createdAt)
        pickedUpAt = try container.decodeIfPresent(Int64.self, forKey: .pickedUpAt)
            ?? legacy.decodeIfPresent(Int64.self, forKey: .pickedUpAt)
        completedAt = try container.decodeIfPresent(Int64.self, forKey: .completedAt)
            ?? legacy.decodeIfPresent(Int64.self, forKey: .completedAt)
        viewedAt = try container.decodeIfPresent(Int64.self, forKey: .viewedAt)
            ?? legacy.decodeIfPresent(Int64.self, forKey: .viewedAt)
    }
}

struct HandoffCreateRequest: Codable {
    let message: String
    let project: String?
    let priority: String
}

struct HandoffCreateResponse: Codable {
    let id: String
}

struct CortanaAgentEvent: Codable, Identifiable {
    let id: String
    let source: String
    let project: String?
    let eventType: String
    let severity: String
    let confidence: String
    let payload: [String: AnyCodable]?
    let recommendedAction: String?
    let executedAction: String?
    let requiresHuman: Bool
    let status: String
    let firstSeenAt: Int64
    let lastSeenAt: Int64
    let resolvedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id, source, project, severity, confidence, payload, status
        case eventType = "event_type"
        case recommendedAction = "recommended_action"
        case executedAction = "executed_action"
        case requiresHuman = "requires_human"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case resolvedAt = "resolved_at"
    }
}

struct CortanaAttentionItem: Codable, Identifiable {
    let id: String
    let project: String?
    let reason: String
    let priority: String
    let linkedEventId: String?
    let linkedTicketId: String?
    let status: String
    let createdAt: Int64
    let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, project, reason, priority, status
        case linkedEventId = "linked_event_id"
        case linkedTicketId = "linked_ticket_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Terminal Stream Event

/// Events yielded by `subscribeToTerminal` — either output data or a terminal error.
enum TerminalStreamEvent: Sendable {
    /// A line of terminal output
    case output(String)
    /// A permanent error that stopped the subscription
    case error(GatewayError)
}

// MARK: - Gateway Error

enum GatewayError: Error, Sendable {
    case requestFailed
    case invalidResponse
    case unauthorized
    case connectionRefused
    case permanentHTTPError(statusCode: Int)
    case terminalNotFound
    case subscriptionFailed(underlying: String)

    /// Whether this error is permanent — retrying won't help.
    var isPermanent: Bool {
        switch self {
        case .unauthorized, .connectionRefused, .terminalNotFound:
            return true
        case .permanentHTTPError(let code):
            // 4xx errors (except 408 Request Timeout, 429 Too Many Requests) are permanent
            return (400...499).contains(code) && code != 408 && code != 429
        case .requestFailed, .invalidResponse, .subscriptionFailed:
            return false
        }
    }
}

extension GatewayError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .requestFailed:
            return "Gateway request failed"
        case .invalidResponse:
            return "Invalid response from gateway"
        case .unauthorized:
            return "Unauthorized — check gateway auth token"
        case .connectionRefused:
            return "Gateway is unreachable"
        case .permanentHTTPError(let code):
            return "Gateway returned HTTP \(code)"
        case .terminalNotFound:
            return "Terminal session not found"
        case .subscriptionFailed(let msg):
            return "Terminal subscription failed: \(msg)"
        }
    }
}

