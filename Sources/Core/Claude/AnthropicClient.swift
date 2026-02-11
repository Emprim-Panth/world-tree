import Foundation

/// Raw HTTP client for the Anthropic Messages API with SSE streaming support.
final class AnthropicClient: Sendable {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    /// Stream a Messages API request, yielding parsed SSE events.
    func stream(request: AnthropicRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = self.buildURLRequest()
                    let encoder = JSONEncoder()
                    urlRequest.httpBody = try encoder.encode(request)

                    let (bytes, response) = try await self.session.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AnthropicClientError.invalidResponse
                    }

                    // Handle non-200 responses
                    if httpResponse.statusCode != 200 {
                        try self.handleErrorResponse(
                            status: httpResponse.statusCode,
                            headers: httpResponse,
                            bytes: bytes,
                            continuation: continuation
                        )
                        return
                    }

                    // Parse SSE stream
                    var currentEventType = ""
                    var dataBuffer = ""

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }

                        if line.hasPrefix("event: ") {
                            currentEventType = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: ") {
                            dataBuffer += String(line.dropFirst(6))
                        } else if line.isEmpty {
                            // End of SSE event
                            if !dataBuffer.isEmpty {
                                if let event = try? self.parseSSEEvent(
                                    type: currentEventType,
                                    data: dataBuffer
                                ) {
                                    continuation.yield(event)

                                    // Stop on message_stop
                                    if case .messageStop = event {
                                        break
                                    }
                                }
                            }
                            currentEventType = ""
                            dataBuffer = ""
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Request Building

    private func buildURLRequest() -> URLRequest {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    // MARK: - Error Handling

    private func handleErrorResponse(
        status: Int,
        headers: HTTPURLResponse,
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<SSEEvent, Error>.Continuation
    ) throws {
        switch status {
        case 429:
            let retryAfter = headers.value(forHTTPHeaderField: "retry-after")
                .flatMap { TimeInterval($0) }
            throw AnthropicClientError.rateLimited(retryAfter: retryAfter)
        case 529:
            throw AnthropicClientError.overloaded
        default:
            // Try to read error body
            throw AnthropicClientError.httpError(status: status, body: "HTTP \(status)")
        }
    }

    // MARK: - SSE Parsing

    private func parseSSEEvent(type: String, data: String) throws -> SSEEvent? {
        guard let jsonData = data.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        switch type {
        case "message_start":
            let payload = try decoder.decode(MessageStartPayload.self, from: jsonData)
            return .messageStart(payload)

        case "content_block_start":
            let payload = try decoder.decode(ContentBlockStartPayload.self, from: jsonData)
            return .contentBlockStart(payload)

        case "content_block_delta":
            let payload = try decoder.decode(ContentBlockDeltaPayload.self, from: jsonData)
            return .contentBlockDelta(payload)

        case "content_block_stop":
            // Extract index from {"type":"content_block_stop","index":N}
            struct StopPayload: Decodable { let index: Int }
            let payload = try decoder.decode(StopPayload.self, from: jsonData)
            return .contentBlockStop(index: payload.index)

        case "message_delta":
            let payload = try decoder.decode(MessageDeltaPayload.self, from: jsonData)
            return .messageDelta(payload)

        case "message_stop":
            return .messageStop

        case "ping":
            return .ping

        case "error":
            let error = try decoder.decode(APIError.self, from: jsonData)
            return .error(error)

        default:
            return nil
        }
    }
}
