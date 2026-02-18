import Foundation

/// Debug logger that writes to a file (print() doesn't work in GUI apps launched outside Xcode)
func canvasLog(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    let path = FileManager.default.homeDirectoryForCurrentUser.path + "/.cortana/logs/canvas-debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) { handle.write(data) }
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
    print(msg) // Also print for Xcode console
}

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

                    if let bodyData = urlRequest.httpBody,
                       let bodyStr = String(data: bodyData, encoding: .utf8) {
                        canvasLog("[AnthropicClient] request: model + tokens at byte 0..\(min(bodyStr.count, 200))")
                        // Log key fields instead of raw body to see model clearly
                        if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                            let model = json["model"] as? String ?? "MISSING"
                            let msgs = (json["messages"] as? [[String: Any]])?.count ?? 0
                            let sys = (json["system"] as? [[String: Any]])?.count ?? 0
                            canvasLog("[AnthropicClient] request fields: model=\(model), messages=\(msgs), system_blocks=\(sys), body_bytes=\(bodyData.count)")
                        }
                    }
                    canvasLog("[AnthropicClient] sending request to \(self.baseURL)")
                    let (bytes, response) = try await self.session.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        canvasLog("[AnthropicClient] invalid response (not HTTPURLResponse)")
                        throw AnthropicClientError.invalidResponse
                    }

                    canvasLog("[AnthropicClient] HTTP \(httpResponse.statusCode)")

                    // Handle non-200 responses
                    if httpResponse.statusCode != 200 {
                        try await self.handleErrorResponse(
                            status: httpResponse.statusCode,
                            headers: httpResponse,
                            bytes: bytes,
                            continuation: continuation
                        )
                        return
                    }

                    // Parse SSE stream
                    // NOTE: URLSession.AsyncBytes.lines strips empty lines,
                    // so we flush the buffered event when a new "event:" arrives
                    // rather than relying on empty-line delimiters.
                    var currentEventType = ""
                    var dataBuffer = ""
                    var lineCount = 0
                    var eventCount = 0
                    var shouldStop = false

                    /// Flush buffered data as a parsed SSE event
                    func flushEvent() throws -> Bool {
                        guard !dataBuffer.isEmpty else { return false }
                        eventCount += 1
                        do {
                            if let event = try self.parseSSEEvent(
                                type: currentEventType,
                                data: dataBuffer
                            ) {
                                continuation.yield(event)
                                if case .messageStop = event {
                                    return true // signal stop
                                }
                            }
                        } catch {
                            canvasLog("[AnthropicClient] SSE parse error #\(eventCount) for '\(currentEventType)': \(error)")
                            canvasLog("[AnthropicClient] data: \(String(dataBuffer.prefix(300)))")
                        }
                        return false
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled || shouldStop { break }
                        lineCount += 1

                        if line.hasPrefix("event: ") {
                            // New event starting — flush any previous buffered event
                            if !dataBuffer.isEmpty {
                                shouldStop = try flushEvent()
                                dataBuffer = ""
                            }
                            currentEventType = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: ") {
                            dataBuffer += String(line.dropFirst(6))
                        } else if line.isEmpty {
                            // Also handle empty lines if they do appear
                            if !dataBuffer.isEmpty {
                                shouldStop = try flushEvent()
                                dataBuffer = ""
                                currentEventType = ""
                            }
                        }
                    }

                    // Flush any remaining buffered event after stream ends
                    if !dataBuffer.isEmpty && !shouldStop {
                        _ = try flushEvent()
                    }

                    canvasLog("[AnthropicClient] SSE stream ended: \(lineCount) lines, \(eventCount) events")

                    continuation.finish()
                } catch {
                    canvasLog("[AnthropicClient] stream error: \(error)")
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
    ) async throws {
        // Read the actual error body — try raw bytes first (more reliable than .lines for JSON)
        var bodyData = Data()
        do {
            for try await byte in bytes {
                bodyData.append(byte)
                if bodyData.count > 4000 { break }
            }
        } catch {
            // Ignore read errors — we already have the status code
        }
        let body: String
        if bodyData.isEmpty {
            body = "HTTP \(status) (empty response body)"
        } else {
            body = String(data: bodyData, encoding: .utf8) ?? "HTTP \(status) (unreadable body: \(bodyData.count) bytes)"
        }
        canvasLog("[AnthropicClient] HTTP \(status) error body: \(String(body.prefix(2000)))")

        switch status {
        case 429:
            let retryAfter = headers.value(forHTTPHeaderField: "retry-after")
                .flatMap { TimeInterval($0) }
            throw AnthropicClientError.rateLimited(retryAfter: retryAfter)
        case 529:
            throw AnthropicClientError.overloaded
        default:
            throw AnthropicClientError.httpError(status: status, body: body)
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
