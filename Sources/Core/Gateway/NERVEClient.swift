import Foundation

// MARK: - NERVE Client Errors

enum NERVEClientError: Error, LocalizedError {
    case noToken
    case requestFailed(statusCode: Int)
    case decodingFailed(underlying: Error)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "NERVE auth token not found — check ~/.cortana/nerve.toml or ~/.cortana/ark-gateway.toml"
        case .requestFailed(let code):
            return "NERVE request failed with status \(code)"
        case .decodingFailed(let err):
            return "NERVE response decoding failed: \(err)"
        case .invalidURL:
            return "NERVE constructed an invalid URL"
        }
    }
}

// MARK: - NERVEClient

/// Swift actor wrapping all NERVE HTTP and SSE communication.
///
/// Token loading priority:
///   1. ~/.cortana/nerve.toml  (ui-token field — preferred once NERVE is deployed)
///   2. ~/.cortana/ark-gateway.toml  (auth_token field — current gateway, same port)
///
/// Both files are at hardcoded paths — this is a local-only app running as the same user.
actor NERVEClient {
    static let shared = NERVEClient()

    private let baseURL = URL(string: "http://127.0.0.1:4862")!  // swiftlint:disable:this force_unwrapping
    private let token: String
    private let session: URLSession

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Try nerve.toml (ui-token) first, fall back to ark-gateway.toml (auth_token)
        let resolvedToken: String
        if let t = NERVEClient.readTOMLToken(path: "\(home)/.cortana/nerve.toml", key: "ui-token") {
            resolvedToken = t
        } else if let t = NERVEClient.readTOMLToken(path: "\(home)/.cortana/ark-gateway.toml", key: "auth_token") {
            resolvedToken = t
        } else {
            // If no config file exists yet, use a placeholder — requests will 401 but the
            // app won't crash. NERVE isn't deployed until Phase 1 cutover.
            resolvedToken = ""
        }
        self.token = resolvedToken

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Private TOML Helper

    private static func readTOMLToken(path: String, key: String) -> String? {
        guard let data   = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(key) else { continue }
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: eqIdx)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                return String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Generic HTTP Methods

    func get<T: Decodable>(_ path: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAuthHeader(&request)
        return try await execute(request)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeader(&request)
        request.httpBody = try JSONEncoder().encode(body)
        return try await execute(request)
    }

    func delete(_ path: String) async throws {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        addAuthHeader(&request)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NERVEClientError.requestFailed(statusCode: code)
        }
    }

    // MARK: - Factory Pipeline

    func fetchFactoryProjects() async throws -> [FactoryProject] {
        // TODO: NERVE /v2/nerve/factory not deployed yet — returns empty until Phase 1 cutover
        // When NERVE is live, remove the try? guard and let errors surface.
        do {
            let response: NERVEFactoryListResponse = try await get("v2/nerve/factory")
            return response.projects
        } catch {
            // Gateway is running but NERVE endpoints don't exist yet — return empty array
            return []
        }
    }

    func fetchFactoryProject(id: String) async throws -> FactoryProject {
        return try await get("v2/nerve/factory/\(id)")
    }

    func createFactoryProject(prompt: String) async throws -> FactoryProject {
        struct Body: Encodable { let prompt: String }
        let response: FactoryProject = try await post("v2/nerve/factory", body: Body(prompt: prompt))
        return response
    }

    func answerFactoryQuestion(projectId: String, answer: String) async throws {
        struct Body: Encodable { let answer: String }
        let _: EmptyResponse = try await post("v2/nerve/factory/\(projectId)/answer", body: Body(answer: answer))
    }

    // MARK: - Crew Sessions

    func fetchCrewSessions() async throws -> [NERVECrewSession] {
        do {
            // TODO: exact endpoint path — confirm with NERVE build once deployed
            let response: NERVECrewSessionListResponse = try await get("v2/nerve/crew/sessions")
            return response.sessions
        } catch {
            return []
        }
    }

    // MARK: - SSE Subscription

    /// Subscribes to the NERVE SSE stream at `/v2/nerve/stream`.
    /// Returns a `Task` that the caller can cancel to unsubscribe.
    /// Each parsed `NERVEEvent` is delivered to `handler` on an arbitrary thread — callers
    /// must dispatch to `@MainActor` themselves if UI updates are needed.
    nonisolated func subscribeToStream(handler: @escaping @Sendable (NERVEEvent) -> Void) -> Task<Void, Never> {
        Task {
            let url  = URL(string: "http://127.0.0.1:4862/v2/nerve/stream")!  // swiftlint:disable:this force_unwrapping
            let tok  = await self.token
            var request = URLRequest(url: url)
            request.setValue(tok, forHTTPHeaderField: "x-cortana-token")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            // No timeout on SSE connection — server sends keep-alives
            request.timeoutInterval = .infinity

            // Reconnect loop — NERVE restarts are expected during Cortana 2.0 migration
            while !Task.isCancelled {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else {
                        // Endpoint not yet deployed — wait before retrying
                        try await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                        continue
                    }

                    var buffer = ""
                    for try await line in bytes.lines {
                        guard !Task.isCancelled else { break }
                        if line.hasPrefix("data:") {
                            let jsonStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            buffer += jsonStr
                        } else if line.isEmpty && !buffer.isEmpty {
                            // Blank line = end of SSE event block
                            if let data  = buffer.data(using: .utf8),
                               let event = try? JSONDecoder().decode(NERVEEvent.self, from: data) {
                                handler(event)
                            }
                            buffer = ""
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { break }
                    // Brief back-off before reconnect
                    try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                }
            }
        }
    }

    // MARK: - Private Helpers

    private func addAuthHeader(_ request: inout URLRequest) {
        request.setValue(token, forHTTPHeaderField: "x-cortana-token")
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NERVEClientError.requestFailed(statusCode: 0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw NERVEClientError.requestFailed(statusCode: http.statusCode)
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw NERVEClientError.decodingFailed(underlying: error)
        }
    }
}

// MARK: - Internal Helpers

/// Placeholder response type for fire-and-forget POSTs that return minimal JSON.
private struct EmptyResponse: Codable {}
