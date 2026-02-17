import Foundation

// MARK: - RemoteCanvasProvider

/// LLM provider that routes messages to a remote CortanaCanvas server (Studio Mac).
///
/// When enabled, messages are sent to a remote CanvasServer via HTTP/SSE instead
/// of being processed locally. Tokens stream back in real time — the UI experience
/// is identical to local providers.
///
/// Remote URL is the Studio's ngrok URL (or LAN IP). Token is the x-canvas-token
/// configured in Studio Canvas → Settings → Server.
final class RemoteCanvasProvider: LLMProvider {
    let displayName = "Remote Studio"
    let identifier = "remote-canvas"
    let capabilities: ProviderCapabilities = [
        .streaming, .sessionResume
    ]

    private(set) var isRunning = false

    private let serverURL: URL
    private let token: String
    private var currentTask: Task<Void, Never>?
    private var isCancelled = false

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300   // 5 min — long Claude responses
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    init(serverURL: URL, token: String) {
        self.serverURL = serverURL
        self.token = token
    }

    // MARK: - Health

    func checkHealth() async -> ProviderHealth {
        let healthURL = serverURL.appendingPathComponent("health")
        var req = URLRequest(url: healthURL)
        req.timeoutInterval = 5
        req.setValue(token, forHTTPHeaderField: "x-canvas-token")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .unavailable(reason: "Server returned non-200")
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if json?["status"] as? String == "ok" {
                return .available
            }
            return .degraded(reason: "Unexpected health response")
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    // MARK: - Send

    func send(context: ProviderSendContext) -> AsyncStream<BridgeEvent> {
        isCancelled = false
        isRunning = true

        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.yield(.error("Provider deallocated"))
                continuation.finish()
                return
            }

            self.currentTask = Task { [weak self] in
                guard let self else { return }
                defer { Task { @MainActor in self.isRunning = false } }

                do {
                    try await self.streamMessage(context: context, continuation: continuation)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    func cancel() {
        isCancelled = true
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - SSE Streaming

    private func streamMessage(
        context: ProviderSendContext,
        continuation: AsyncStream<BridgeEvent>.Continuation
    ) async throws {

        let endpoint = serverURL.appendingPathComponent("api/message")

        // Build request
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(token, forHTTPHeaderField: "x-canvas-token")
        req.timeoutInterval = 300

        let body: [String: Any] = [
            "session_id": context.sessionId,
            "content": context.message,
            "project": context.project ?? ""
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        canvasLog("[RemoteCanvas] POST \(endpoint) session=\(context.sessionId)")

        let (bytes, response) = try await session.bytes(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw RemoteCanvasError.invalidResponse
        }

        if http.statusCode == 401 {
            throw RemoteCanvasError.unauthorized
        }
        if http.statusCode != 200 {
            throw RemoteCanvasError.serverError(http.statusCode)
        }

        // Parse SSE stream — lines() strips empty lines, we rely on data: prefix
        for try await line in bytes.lines {
            if isCancelled { break }
            guard line.hasPrefix("data: ") else { continue }

            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let token = event["token"] as? String {
                continuation.yield(.text(token))

            } else if let done = event["done"] as? Bool, done {
                continuation.yield(.done(usage: SessionTokenUsage()))
                continuation.finish()
                return

            } else if let errMsg = event["error"] as? String {
                continuation.yield(.error(errMsg))
                continuation.finish()
                return

            } else if let name = event["tool_start"] as? String {
                continuation.yield(.toolStart(name: name, input: ""))

            } else if let name = event["tool_end"] as? String {
                let isError = event["error"] as? Bool ?? false
                continuation.yield(.toolEnd(name: name, result: "", isError: isError))
            }
        }

        // Stream ended without explicit done event
        continuation.yield(.done(usage: SessionTokenUsage()))
        continuation.finish()
    }
}

// MARK: - Errors

enum RemoteCanvasError: LocalizedError {
    case invalidResponse
    case unauthorized
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from Canvas server"
        case .unauthorized: return "Canvas token rejected — update it in Settings → Server"
        case .serverError(let code): return "Canvas server returned HTTP \(code)"
        }
    }
}
