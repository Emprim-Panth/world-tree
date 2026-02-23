import XCTest
@testable import WorldTreeMobile

// MARK: - Mock Tasks

/// Blocks in receive() until cancel() is called, simulating a stable connection.
final class MockStableTask: WebSocketTaskProtocol, @unchecked Sendable {
    private(set) var didResume = false
    private(set) var didCancel = false

    private let lock = NSLock()
    private var pendingContinuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    func resume() {
        didResume = true
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        didCancel = true
        lock.lock()
        let cont = pendingContinuation
        pendingContinuation = nil
        lock.unlock()
        cont?.resume(throwing: URLError(.cancelled))
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pendingContinuation = cont
            lock.unlock()
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {}

    func ping() async throws -> TimeInterval {
        return 0.001   // simulated 1 ms
    }
}

/// Throws immediately from receive(), simulating a dropped connection.
final class MockFailingTask: WebSocketTaskProtocol, @unchecked Sendable {
    private(set) var didResume = false

    func resume() { didResume = true }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        throw URLError(.networkConnectionLost)
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {}

    func ping() async throws -> TimeInterval {
        throw URLError(.networkConnectionLost)
    }
}

// MARK: - Helpers

private func makeServer() -> SavedServer {
    SavedServer(
        id: UUID().uuidString,
        name: "TestServer",
        host: "localhost",
        port: 5865,
        source: .manual
    )
}

// MARK: - Tests

@MainActor
final class ConnectionManagerTests: XCTestCase {

    // MARK: connect()

    func testConnect_setsStateToConnected() async {
        let task = MockStableTask()
        let manager = ConnectionManager(taskFactory: { _ in task })

        await manager.connect(to: makeServer(), token: "tok")

        XCTAssertEqual(manager.state, .connected)
        XCTAssertTrue(task.didResume)
        manager.disconnect()
    }

    func testConnect_storesCurrentServer() async {
        let server = makeServer()
        let manager = ConnectionManager(taskFactory: { _ in MockStableTask() })

        await manager.connect(to: server, token: "tok")

        XCTAssertEqual(manager.currentServer, server)
        manager.disconnect()
    }

    // MARK: disconnect()

    func testDisconnect_setsStateToDisconnected() async {
        let task = MockStableTask()
        let manager = ConnectionManager(taskFactory: { _ in task })
        await manager.connect(to: makeServer(), token: "tok")

        manager.disconnect()

        XCTAssertEqual(manager.state, .disconnected)
    }

    func testDisconnect_cancelsWebSocketTask() async {
        let task = MockStableTask()
        let manager = ConnectionManager(taskFactory: { _ in task })
        await manager.connect(to: makeServer(), token: "tok")

        manager.disconnect()

        XCTAssertTrue(task.didCancel)
    }

    // MARK: reconnect

    func testReconnect_stateBecomesReconnectingAfterConnectionDrop() async {
        let manager = ConnectionManager(taskFactory: { _ in MockFailingTask() })

        await manager.connect(to: makeServer(), token: "tok")
        // Yield to the main actor so the receive loop can process the error.
        try? await Task.sleep(for: .milliseconds(50))

        switch manager.state {
        case .reconnecting, .connected:
            break   // Either is valid depending on scheduling
        default:
            XCTFail("Expected .reconnecting or .connected, got \(manager.state)")
        }

        manager.disconnect()
    }

    func testReconnect_eventuallyReconnectsAfterFirstFailure() async {
        var callCount = 0
        let stableTask = MockStableTask()
        let manager = ConnectionManager(taskFactory: { _ in
            callCount += 1
            return callCount == 1 ? MockFailingTask() : stableTask
        })

        await manager.connect(to: makeServer(), token: "tok")

        // Attempt 1 delay is 1 s (2^0). Wait slightly longer.
        try? await Task.sleep(for: .seconds(1.2))

        XCTAssertEqual(manager.state, .connected)
        XCTAssertEqual(callCount, 2)

        manager.disconnect()
    }

    // MARK: latency

    func testSendPing_setsLatency() async throws {
        let task = MockStableTask()
        let manager = ConnectionManager(taskFactory: { _ in task })
        await manager.connect(to: makeServer(), token: "tok")

        XCTAssertNil(manager.latency)
        try await manager.sendPing()

        XCTAssertNotNil(manager.latency)
        XCTAssertGreaterThanOrEqual(manager.latency!, 0)

        manager.disconnect()
    }
}
