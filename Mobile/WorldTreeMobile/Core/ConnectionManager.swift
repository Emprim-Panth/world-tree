import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Dedicated session for WebSocket connections: ephemeral config avoids any shared-session
/// TLS delegate or proxy customization that could interfere with WebSocket handshake validation.
private let _wsSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
}()

// MARK: - WebSocket Testability

/// Abstraction over URLSessionWebSocketTask for unit-testability.
/// Uses an async `ping()` rather than the closure-based sendPing to avoid
/// Sendable-closure mismatches under strict concurrency checking.
protocol WebSocketTaskProtocol: Sendable {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    /// Send a ping and return the round-trip time in seconds.
    func ping() async throws -> TimeInterval
}

// Bridge URLSessionWebSocketTask's closure-based sendPing to the async ping().
// No @retroactive: WebSocketTaskProtocol is declared in this module.
extension URLSessionWebSocketTask: WebSocketTaskProtocol {
    func ping() async throws -> TimeInterval {
        let start = Date()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sendPing { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
        return Date().timeIntervalSince(start)
    }
}

// MARK: - Observation Token Holder

/// Holds NotificationCenter observer tokens and removes them on dealloc.
/// Declared as a separate class so its `deinit` runs without needing @MainActor isolation.
private final class ObserverHolder: @unchecked Sendable {
    var tokens: [any NSObjectProtocol] = []

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

// MARK: - ConnectionManager

/// Manages the WebSocket lifecycle: connect, disconnect, exponential-backoff
/// reconnect, latency measurement, and background/foreground transitions.
///
/// Implements FRD-004-005 through FRD-004-010.
@Observable
@MainActor
final class ConnectionManager {

    // MARK: - State

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    // MARK: - Public

    private(set) var state: State = .disconnected
    var currentServer: SavedServer?
    /// Round-trip time of the last successful ping (seconds).
    var latency: TimeInterval?
    /// Set to true when the user explicitly taps "Change Server".
    /// Prevents autoConnectIfNeeded from reconnecting to the last server.
    /// Cleared automatically when connect(to:token:) is called.
    var suppressAutoConnect: Bool = false

    // MARK: - Private

    private var webSocketTask: (any WebSocketTaskProtocol)?
    /// Incremented on every new connection and on explicit disconnect.
    /// Receive loops capture their generation at start; mismatches mean
    /// the loop is stale and should not trigger reconnect.
    private var connectionGeneration = 0
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var backgroundTimer: Task<Void, Never>?
    private let taskFactory: @Sendable (URL) -> any WebSocketTaskProtocol

    // `let` constant — accessible from nonisolated deinit.
    // ObserverHolder.deinit removes the notification observers.
    private let observers = ObserverHolder()

    // MARK: - Init

    init(taskFactory: (@Sendable (URL) -> any WebSocketTaskProtocol)? = nil) {
        self.taskFactory = taskFactory ?? { url in
            _wsSession.webSocketTask(with: url)
        }
        setupBackgroundHandling()
    }

    // MARK: - Public API

    /// Connect to `server`. No auth required — token parameter kept for call-site compat.
    /// Resets the reconnect counter and cancels any pending reconnect first.
    func connect(to server: SavedServer, token: String = "") async {
        suppressAutoConnect = false
        currentServer = server
        reconnectAttempts = 0
        cancelReconnect()
        state = .connecting
        await openWebSocket(server: server)
    }

    /// Immediately close the socket and cancel all background work.
    func disconnect() {
        connectionGeneration += 1      // invalidates any running receive loops
        cancelReconnect()
        cancelPing()
        cancelBackgroundTimer()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        state = .disconnected
        reconnectAttempts = 0
    }

    /// Send a WebSocket ping and update `latency` with the round-trip time.
    func sendPing() async throws {
        guard let task = webSocketTask else { return }
        latency = try await task.ping()
    }

    /// Encode and send a client command over the WebSocket. Silently no-ops when disconnected.
    func send(_ command: ClientCommand) async {
        guard let json = MessageParser.encode(command),
              let task = webSocketTask else { return }
        try? await task.send(.string(json))
    }

    // MARK: - WebSocket Lifecycle

    private func openWebSocket(server: SavedServer) async {
        // For ngrok-tunnelled hosts (.ngrok-free.app, .ngrok.io, etc.) the WebSocket
        // travels over ngrok's HTTPS tunnel — use wss:// with no explicit port (443).
        // For local LAN and Tailscale connections use ws:// on the native wsPort (5866).
        let isNgrok = server.host.contains(".ngrok")
        let urlString = isNgrok
            ? "wss://\(server.host)/ws"
            : "ws://\(server.host):\(Constants.Network.wsPort)/ws"
        guard let url = URL(string: urlString) else {
            state = .disconnected
            return
        }
        connectionGeneration += 1
        let generation = connectionGeneration
        let task = taskFactory(url)
        webSocketTask = task
        task.resume()
        state = .connected
        startReceiveLoop(task: task, generation: generation, server: server)
        startPingLoop()
        // No auth handshake — server accepts all connections.
        await send(.listTrees())
    }

    private func startReceiveLoop(
        task: any WebSocketTaskProtocol,
        generation: Int,
        server: SavedServer
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                while self.connectionGeneration == generation {
                    let message = try await task.receive()
                    guard self.connectionGeneration == generation else { break }
                    self.handleMessage(message)
                }
            } catch {
                guard self.connectionGeneration == generation else { return }
                print("[ConnectionManager] WebSocket error: \(error)")
                await self.handleDisconnect(server: server)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            NotificationCenter.default.post(name: .webSocketMessageReceived, object: text)
        default:
            break
        }
    }

    private func handleDisconnect(server: SavedServer) async {
        webSocketTask = nil
        cancelPing()

        guard reconnectAttempts < maxReconnectAttempts else {
            state = .disconnected
            currentServer = nil  // Return to server picker after exhausting all retries
            return
        }
        reconnectAttempts += 1
        state = .reconnecting(attempt: reconnectAttempts)

        // Exponential backoff: 1 → 2 → 4 → 8 → 16 → 30 s (capped)
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), 30.0)
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self.openWebSocket(server: server)
        }
    }

    // MARK: - Ping Loop (FR-004-008 / FR-004-009)

    private func startPingLoop() {
        cancelPing()
        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled, self.state == .connected else { break }
                try? await self.sendPing()
            }
        }
    }

    private func cancelPing() {
        pingTask?.cancel()
        pingTask = nil
    }

    // MARK: - Reconnect

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - Background / Foreground (FR-004-010)

    private func setupBackgroundHandling() {
        #if canImport(UIKit)
        let bg = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleBackground() }
        }
        let fg = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.handleForeground() }
        }
        observers.tokens = [bg, fg]
        #endif
    }

    /// Start the 30-second grace timer before disconnecting in background.
    private func handleBackground() {
        cancelBackgroundTimer()
        backgroundTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            self.backgroundDisconnect()
        }
    }

    /// Cancel the timer; reconnect if the socket was dropped while backgrounded.
    private func handleForeground() async {
        cancelBackgroundTimer()
        guard let server = currentServer else { return }
        switch state {
        case .disconnected, .reconnecting:
            reconnectAttempts = 0
            cancelReconnect()
            await openWebSocket(server: server)
        default:
            break
        }
    }

    private func backgroundDisconnect() {
        connectionGeneration += 1
        cancelReconnect()
        cancelPing()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        state = .disconnected
        // reconnectAttempts not reset — handleForeground resets it on return.
    }

    private func cancelBackgroundTimer() {
        backgroundTimer?.cancel()
        backgroundTimer = nil
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let webSocketMessageReceived = Notification.Name("webSocketMessageReceived")
}
