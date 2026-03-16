import Foundation

/// Direct Claude API service using REST API with streaming
@MainActor
final class ClaudeService {
    static let shared = ClaudeService()

    private var apiKey: String?
    private let baseURL = "https://api.anthropic.com/v1"

    /// Dedicated session with streaming-appropriate timeouts (300s inter-packet).
    private let streamingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300  // 5 min between data packets
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private init() {
        loadAPIKey()
    }

    /// Load API key from Keychain or environment
    private func loadAPIKey() {
        // Try environment variable first
        if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] {
            apiKey = envKey
            return
        }

        // Try Keychain
        if let key = KeychainHelper.load(key: "anthropic_api_key") {
            apiKey = key
            return
        }

        wtLog("[ClaudeService] No API key found - user needs to set it")
    }

    /// Set API key and save to Keychain
    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = trimmed.isEmpty ? nil : trimmed
        if let apiKey {
            KeychainHelper.save(key: "anthropic_api_key", value: apiKey)
            wtLog("[ClaudeService] API key configured")
        } else {
            KeychainHelper.delete(key: "anthropic_api_key")
            wtLog("[ClaudeService] API key cleared")
        }
    }

    /// Check if API key is configured
    var isConfigured: Bool {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    /// Stream a completion from Claude
    func streamCompletion(
        messages: [ClaudeMessage],
        model: String = AppConstants.defaultModel,
        maxTokens: Int = 4096
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let apiKey = apiKey else {
                continuation.finish(throwing: ClaudeServiceError.noAPIKey)
                return
            }

            let task = Task {
                do {
                    let url = URL(string: "\(baseURL)/messages")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")

                    let requestBody: [String: Any] = [
                        "model": model,
                        "max_tokens": maxTokens,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                        "stream": true
                    ]

                    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

                    let (bytes, response) = try await streamingSession.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: ClaudeServiceError.apiError("Invalid response"))
                        return
                    }

                    guard (200...299).contains(httpResponse.statusCode) else {
                        // Try to read error response body
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }

                        let errorMsg = "HTTP \(httpResponse.statusCode): \(errorBody.prefix(200))"
                        continuation.finish(throwing: ClaudeServiceError.apiError(errorMsg))
                        return
                    }

                    // Parse Server-Sent Events stream
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))

                            if jsonString == "[DONE]" {
                                break
                            }

                            if let data = jsonString.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let type = json["type"] as? String {

                                if type == "content_block_delta",
                                   let delta = json["delta"] as? [String: Any],
                                   let text = delta["text"] as? String {
                                    continuation.yield(text)
                                } else if type == "error",
                                          let error = json["error"] as? [String: Any],
                                          let message = error["message"] as? String {
                                    continuation.finish(throwing: ClaudeServiceError.apiError(message))
                                    return
                                }
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // Cancel the spawned Task when the stream is abandoned — prevents leak
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Build message parameters from document sections
    static func buildMessages(from sections: [DocumentSection]) -> [ClaudeMessage] {
        var messages: [ClaudeMessage] = []

        for section in sections {
            let role: String
            switch section.author {
            case .user:
                role = "user"
            case .assistant:
                role = "assistant"
            case .system:
                // System messages handled separately
                continue
            }

            messages.append(
                ClaudeMessage(
                    role: role,
                    content: String(section.content.characters)
                )
            )
        }

        return messages
    }
}

// MARK: - Models

struct ClaudeMessage {
    let role: String
    let content: String
}

// MARK: - Errors

enum ClaudeServiceError: LocalizedError {
    case noAPIKey
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured. Please set your Anthropic API key in Settings."
        case .apiError(let message):
            return "Claude API error: \(message)"
        }
    }
}
