import Foundation

// MARK: - DaemonChannel

/// HTTP SSE client to the openClaude daemon's canvas message endpoint.
///
/// Sends messages to `POST http://localhost:8765/api/v1/canvas/message`
/// and parses the SSE token stream back into BridgeEvents.
///
/// Falls back gracefully — yields `.error` if the daemon is unreachable.
/// ClaudeBridge checks `DaemonService.shared.isConnected` and the
/// `daemonChannelEnabled` preference before routing here.
actor DaemonChannel {
    static let shared = DaemonChannel()

    private init() {}

    /// Dedicated URLSession for SSE streams.
    /// Short request timeout (8 s) so a slow/absent daemon endpoint fails fast
    /// and ClaudeBridge can fall back to the direct provider immediately.
    /// Resource timeout is generous (5 min) so legitimate long streams are not cut.
    private nonisolated static let sseSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 8    // first-byte timeout
        config.timeoutIntervalForResource = 300  // total stream duration
        return URLSession(configuration: config)
    }()

    // MARK: - Configuration

    private var apiURL: String {
        // Allow runtime override; default to constant
        UserDefaults.standard.string(forKey: "cortana.daemonAPIBaseURL")
            ?? AppConstants.daemonAPIURL
    }

    private var apiToken: String {
        UserDefaults.standard.string(forKey: AppConstants.daemonAPITokenKey) ?? ""
    }

    // MARK: - Send

    /// Send a message to the daemon and stream the response as BridgeEvents.
    ///
    /// On connection failure the stream immediately yields `.error` so `ClaudeBridge`
    /// can fall through to the direct ProviderManager path.
    func send(
        text: String,
        project: String?,
        branchId: String?,
        sessionId: String?
    ) -> AsyncStream<BridgeEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "\(self.apiURL)/api/v1/canvas/message") else {
                        continuation.yield(.error("Invalid daemon URL: \(self.apiURL)"))
                        continuation.finish()
                        return
                    }

                    var req = URLRequest(url: url)  // no timeoutInterval — session config governs
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let token = self.apiToken
                    if !token.isEmpty {
                        req.setValue(token, forHTTPHeaderField: "x-api-token")
                    }

                    var payload: [String: Any] = ["text": text]
                    if let project { payload["project"] = project }
                    if let branchId { payload["branch_id"] = branchId }
                    if let sessionId { payload["session_id"] = sessionId }
                    req.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await Self.sseSession.bytes(for: req)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        continuation.yield(.error("Daemon returned HTTP \(http.statusCode)"))
                        continuation.finish()
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let token = json["token"] as? String {
                            continuation.yield(.text(token))
                        } else if let isDone = json["done"] as? Bool, isDone {
                            continuation.yield(.done(usage: SessionTokenUsage()))
                            continuation.finish()
                            return
                        } else if let errMsg = json["error"] as? String {
                            continuation.yield(.error(errMsg))
                            continuation.finish()
                            return
                        }
                    }

                    // Stream ended without explicit done
                    continuation.yield(.done(usage: SessionTokenUsage()))
                    continuation.finish()
                } catch {
                    wtLog("[DaemonChannel] Connection failed: \(error.localizedDescription)")
                    continuation.yield(.error("Daemon channel not available — using direct provider"))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
