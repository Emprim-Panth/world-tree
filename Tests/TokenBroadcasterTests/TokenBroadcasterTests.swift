import XCTest
@testable import WorldTree

// MARK: - TokenBroadcasterTests

/// Verifies the three core behaviours of TokenBroadcaster:
///   1. subscribe  — broadcast() initialises and cleans up the token index
///   2. convert    — convert(event:) maps every BridgeEvent variant to the correct WSMessage type
///   3. broadcast  — broadcast() consumes a stream and cleans up state on completion
@MainActor
final class TokenBroadcasterTests: XCTestCase {

    var broadcaster: TokenBroadcaster { TokenBroadcaster.shared }

    // MARK: - 1. Subscribe: token index lifecycle

    func testSubscribeInitialisesAndCleansUpTokenIndex() async throws {
        let branchId = "tb-test-subscribe-\(UUID().uuidString)"
        let sessionId = "tb-session-subscribe"

        let (stream, continuation) = AsyncStream<BridgeEvent>.makeStream()

        // Start broadcast — index should be 0 after the task body starts
        let task = broadcaster.broadcast(stream: stream, branchId: branchId, sessionId: sessionId)

        // Yield so the task body can execute up to the `for await` suspension point
        await Task.yield()
        XCTAssertEqual(broadcaster.tokenIndexes[branchId], 0,
                       "Token index must be initialised to 0 when broadcast starts")

        // Terminate the stream via error to bypass DB writes
        continuation.yield(.error("test-terminate"))
        continuation.finish()
        await task.value

        XCTAssertNil(broadcaster.tokenIndexes[branchId],
                     "Token index must be removed after stream ends")
    }

    // MARK: - 2. Convert: BridgeEvent → WSMessage frame

    func testConvertMapsAllEventVariants() {
        let branchId = "tb-test-convert-\(UUID().uuidString)"
        let sessionId = "tb-session-convert"
        var accumulated = ""

        // .text → "token" with index 0
        broadcaster.tokenIndexes[branchId] = 0
        let tokenFrame = broadcaster.convert(
            event: .text("Hello"),
            branchId: branchId,
            sessionId: sessionId,
            accumulated: &accumulated
        )
        XCTAssertEqual(tokenFrame?.type, "token")
        XCTAssertEqual(accumulated, "Hello")
        XCTAssertEqual(broadcaster.tokenIndexes[branchId], 1, "Index must increment after each token")

        // .text again → index 1
        let tokenFrame2 = broadcaster.convert(
            event: .text(", world"),
            branchId: branchId,
            sessionId: sessionId,
            accumulated: &accumulated
        )
        XCTAssertEqual(tokenFrame2?.type, "token")
        XCTAssertEqual(broadcaster.tokenIndexes[branchId], 2)

        // .toolStart → "tool_status"
        let toolStartFrame = broadcaster.convert(
            event: .toolStart(name: "bash", input: "{}"),
            branchId: branchId,
            sessionId: sessionId,
            accumulated: &accumulated
        )
        XCTAssertEqual(toolStartFrame?.type, "tool_status")

        // .toolEnd (success) → "tool_status"
        let toolEndFrame = broadcaster.convert(
            event: .toolEnd(name: "bash", result: "ok", isError: false),
            branchId: branchId,
            sessionId: sessionId,
            accumulated: &accumulated
        )
        XCTAssertEqual(toolEndFrame?.type, "tool_status")

        // .toolEnd (error) → "tool_status"
        let toolErrorFrame = broadcaster.convert(
            event: .toolEnd(name: "bash", result: "fail", isError: true),
            branchId: branchId,
            sessionId: sessionId,
            accumulated: &accumulated
        )
        XCTAssertEqual(toolErrorFrame?.type, "tool_status")

        // .error → "error"
        let errorFrame = broadcaster.convert(
            event: .error("something went wrong"),
            branchId: branchId,
            sessionId: sessionId,
            accumulated: &accumulated
        )
        XCTAssertEqual(errorFrame?.type, "error")
    }

    // MARK: - 3. Broadcast: stream drives the task to completion

    func testBroadcastConsumesStreamAndCleansUp() async throws {
        let branchId = "tb-test-broadcast-\(UUID().uuidString)"
        let sessionId = "tb-session-broadcast"

        let (stream, continuation) = AsyncStream<BridgeEvent>.makeStream()

        let task = broadcaster.broadcast(stream: stream, branchId: branchId, sessionId: sessionId)
        await Task.yield()

        // Emit a few token events
        continuation.yield(.text("one"))
        continuation.yield(.text("two"))
        continuation.yield(.text("three"))
        // Terminate cleanly via error (avoids DB writes in test environment)
        continuation.yield(.error("test-done"))
        continuation.finish()

        await task.value

        // All state must be cleaned up
        XCTAssertNil(broadcaster.tokenIndexes[branchId],
                     "Token index must be nil after broadcast completes")
    }
}
