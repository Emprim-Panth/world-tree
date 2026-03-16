import XCTest
@testable import WorldTree

@MainActor
final class ActiveStreamRegistryTests: XCTestCase {
    func testStartStreamPostsActiveStreamStartedNotification() async {
        let branchId = "branch-\(UUID().uuidString)"
        let sessionId = "session-\(UUID().uuidString)"
        let started = expectation(description: "active stream started notification")

        let observer = NotificationCenter.default.addObserver(
            forName: .activeStreamStarted,
            object: nil,
            queue: .main
        ) { note in
            guard let noteBranchId = note.userInfo?["branchId"] as? String,
                  let noteSessionId = note.userInfo?["sessionId"] as? String,
                  noteBranchId == branchId,
                  noteSessionId == sessionId else { return }
            started.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let (stream, continuation) = AsyncStream<BridgeEvent>.makeStream()

        _ = ActiveStreamRegistry.shared.startStream(
            branchId: branchId,
            sessionId: sessionId,
            treeId: nil,
            projectName: nil,
            stream: stream
        )

        continuation.yield(.done(usage: SessionTokenUsage()))
        continuation.finish()

        await fulfillment(of: [started], timeout: 1.0)
    }

    func testLateSubscriberCanCatchUpAndReceiveFutureEvents() async {
        let branchId = "branch-\(UUID().uuidString)"
        let sessionId = "session-\(UUID().uuidString)"
        let futureToken = expectation(description: "late subscriber receives future token")

        let (stream, continuation) = AsyncStream<BridgeEvent>.makeStream()
        _ = ActiveStreamRegistry.shared.startStream(
            branchId: branchId,
            sessionId: sessionId,
            treeId: nil,
            projectName: nil,
            stream: stream
        )

        continuation.yield(.text("Recovered"))

        let replayedContent = expectation(description: "registry replays accumulated content")
        Task { @MainActor in
            for _ in 0..<40 {
                if ActiveStreamRegistry.shared.currentContent(for: branchId) == "Recovered" {
                    replayedContent.fulfill()
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        await fulfillment(of: [replayedContent], timeout: 1.5)

        let subscriptionId = ActiveStreamRegistry.shared.subscribe(branchId: branchId) { event in
            if case .text(let token) = event, token == " stream" {
                futureToken.fulfill()
            }
        }
        defer { ActiveStreamRegistry.shared.unsubscribe(branchId: branchId, id: subscriptionId) }

        continuation.yield(.text(" stream"))
        continuation.yield(.done(usage: SessionTokenUsage()))
        continuation.finish()

        await fulfillment(of: [futureToken], timeout: 1.0)
    }

    func testInitialRecoveryContentSeedsRegistryBeforeNewTokensArrive() async {
        let branchId = "branch-\(UUID().uuidString)"
        let sessionId = "session-\(UUID().uuidString)"
        let seededContent = "Partial sentence"

        let (stream, continuation) = AsyncStream<BridgeEvent>.makeStream()
        _ = ActiveStreamRegistry.shared.startStream(
            branchId: branchId,
            sessionId: sessionId,
            treeId: nil,
            projectName: nil,
            initialContent: seededContent,
            stream: stream
        )

        XCTAssertEqual(
            ActiveStreamRegistry.shared.currentContent(for: branchId),
            seededContent
        )

        continuation.yield(.text(" continued"))
        continuation.yield(.done(usage: SessionTokenUsage()))
        continuation.finish()
    }

    func testRecoverySeedAloneDoesNotQualifyForPersistence() {
        XCTAssertFalse(
            ActiveStreamRegistry.shouldPersistAccumulatedContent(
                accumulatedContent: "Partial sentence",
                initialContent: "Partial sentence",
                receivedText: false
            )
        )
    }

    func testRecoverySeedPlusNewTextQualifiesForPersistence() {
        XCTAssertTrue(
            ActiveStreamRegistry.shouldPersistAccumulatedContent(
                accumulatedContent: "Partial sentence continued",
                initialContent: "Partial sentence",
                receivedText: true
            )
        )
    }

    func testFreshStreamTextQualifiesForPersistence() {
        XCTAssertTrue(
            ActiveStreamRegistry.shouldPersistAccumulatedContent(
                accumulatedContent: "Fresh response",
                initialContent: "",
                receivedText: true
            )
        )
    }
}
