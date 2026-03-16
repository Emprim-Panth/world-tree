import Foundation

// MARK: - Ollama HTTP Client

/// Lightweight HTTP client for Ollama. Thread-safe Swift actor.
/// Used by OllamaProvider (streaming UI conversations) and CoordinatorActor (non-streaming coordination).
actor OllamaClient {
    static let shared = OllamaClient()

    private let baseURL = URL(string: "http://localhost:11434")!
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - Health

    /// Returns true if Ollama is running and reachable.
    func isRunning() async -> Bool {
        do {
            var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
            req.timeoutInterval = 3
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Returns model names available in this Ollama installation.
    func availableModels() async -> [String] {
        do {
            let (data, _) = try await session.data(from: baseURL.appendingPathComponent("api/tags"))
            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return decoded.models.map { $0.name }
        } catch {
            return []
        }
    }

    // MARK: - Non-Streaming Chat (for CoordinatorActor)

    /// Blocking chat — waits for the full response. Used for coordinator task decomposition and review.
    func chat(model: String, messages: [OllamaChatMessage]) async throws -> String {
        let body = OllamaChatRequest(model: model, messages: messages, stream: false)
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 120

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw OllamaError.httpError(http.statusCode, body)
        }
        let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        return decoded.message.content
    }

    // MARK: - Streaming Chat (for OllamaProvider)

    /// Streaming chat — yields text chunks as they arrive.
    func chatStream(model: String, messages: [OllamaChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let body = OllamaChatRequest(model: model, messages: messages, stream: true)
                    var req = URLRequest(url: self.baseURL.appendingPathComponent("api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONEncoder().encode(body)
                    req.timeoutInterval = 300

                    let (bytes, httpResponse) = try await self.session.bytes(for: req)
                    if let http = httpResponse as? HTTPURLResponse, http.statusCode != 200 {
                        throw OllamaError.httpError(http.statusCode, "streaming request failed")
                    }

                    for try await line in bytes.lines {
                        guard !line.isEmpty else { continue }
                        guard let lineData = line.data(using: .utf8) else { continue }
                        let chunk = try JSONDecoder().decode(OllamaChatStreamChunk.self, from: lineData)
                        let text = chunk.message.content
                        if !text.isEmpty {
                            continuation.yield(text)
                        }
                        if chunk.done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Error

enum OllamaError: LocalizedError {
    case httpError(Int, String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body): return "Ollama HTTP \(code): \(body)"
        case .parseError(let msg): return "Ollama parse error: \(msg)"
        }
    }
}

// MARK: - API Types

struct OllamaChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

private struct OllamaChatRequest: Codable {
    let model: String
    let messages: [OllamaChatMessage]
    let stream: Bool
}

private struct OllamaChatResponse: Codable {
    let message: OllamaChatMessage
}

private struct OllamaChatStreamChunk: Codable {
    let message: OllamaChatMessage
    let done: Bool
}

private struct OllamaTagsResponse: Codable {
    struct ModelInfo: Codable {
        let name: String
    }
    let models: [ModelInfo]
}
