import Foundation

/// HTTP client for connecting Canvas to the Ark Gateway
actor GatewayClient {
    private let baseURL: URL
    private let authToken: String
    private let session: URLSession

    init(baseURL: String = "http://localhost:4862", authToken: String) {
        self.baseURL = URL(string: baseURL)!
        self.authToken = authToken
        self.session = URLSession.shared
    }

    // MARK: - Memory Operations

    func logMemory(
        category: String,
        content: String,
        project: String?,
        tags: [String]? = nil
    ) async throws -> Int64 {
        let endpoint = baseURL.appendingPathComponent("/v1/cortana/memory/log")
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
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/v1/cortana/memory/search"),
            resolvingAgainstBaseURL: false
        )!

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

        var request = URLRequest(url: components.url!)
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
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/v1/cortana/handoffs"),
            resolvingAgainstBaseURL: false
        )!

        if let project = project {
            components.queryItems = [URLQueryItem(name: "project", value: project)]
        }

        var request = URLRequest(url: components.url!)
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
        let endpoint = baseURL.appendingPathComponent("/v1/cortana/handoffs")
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
        let endpoint = baseURL.appendingPathComponent("/v1/cortana/handoffs/\(id)/status")
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

    // MARK: - Terminal Operations

    func createTerminal(
        command: String = "bash",
        args: [String]? = nil,
        cwd: String? = nil,
        project: String? = nil,
        name: String? = nil
    ) async throws -> TerminalSession {
        let endpoint = baseURL.appendingPathComponent("/v1/cortana/terminal/start")
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
        let endpoint = baseURL.appendingPathComponent("/v1/cortana/terminal/list")
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
        let endpoint = baseURL.appendingPathComponent("/v1/cortana/terminal/\(sessionId)/kill")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GatewayError.requestFailed
        }
    }

    nonisolated func subscribeToTerminal(sessionId: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                let url = baseURL.appendingPathComponent("/v1/cortana/terminal/\(sessionId)/stream")
                var request = URLRequest(url: url)
                request.setValue(authToken, forHTTPHeaderField: "x-cortana-token")

                do {
                    let (bytes, _) = try await session.bytes(for: request)

                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                } catch {
                    continuation.finish()
                }
            }
        }
    }

    func sendTerminalCommand(sessionId: String, command: String) async throws {
        let endpoint = baseURL.appendingPathComponent("/v1/cortana/terminal/\(sessionId)/input")
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
}

struct HandoffCreateRequest: Codable {
    let message: String
    let project: String?
    let priority: String
}

struct HandoffCreateResponse: Codable {
    let id: String
}

enum GatewayError: Error {
    case requestFailed
    case invalidResponse
    case unauthorized
}

