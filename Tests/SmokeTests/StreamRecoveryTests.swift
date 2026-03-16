import XCTest
@testable import WorldTree

@MainActor
final class StreamRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: StreamRecoveryStore!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "StreamRecoveryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = StreamRecoveryStore(
            defaults: defaults,
            notificationCenter: NotificationCenter()
        )
    }

    override func tearDown() async throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        store = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testPendingRecoveryPersistsAcrossStoreInstances() {
        let sessionId = UUID().uuidString

        store.markPending(sessionId: sessionId, partialContent: "partial")

        let reloaded = StreamRecoveryStore(
            defaults: defaults,
            notificationCenter: NotificationCenter()
        )

        XCTAssertTrue(reloaded.hasPendingRecovery(sessionId: sessionId))
        XCTAssertEqual(reloaded.pendingRecovery(for: sessionId)?.partialContent, "partial")
    }

    func testClearingPendingRecoveryRemovesRecord() {
        let sessionId = UUID().uuidString

        store.markPending(sessionId: sessionId)
        store.clearPending(sessionId: sessionId)

        XCTAssertFalse(store.hasPendingRecovery(sessionId: sessionId))
    }

    func testMarkAttemptStartedIncrementsAttemptCountAndPersistsTimestamp() {
        let sessionId = UUID().uuidString

        store.markPending(sessionId: sessionId, partialContent: "partial")
        let updated = store.markAttemptStarted(sessionId: sessionId)

        XCTAssertEqual(updated?.attemptCount, 1)
        XCTAssertNotNil(updated?.lastAttemptAt)
        XCTAssertEqual(updated?.partialContent, "partial")

        let reloaded = StreamRecoveryStore(
            defaults: defaults,
            notificationCenter: NotificationCenter()
        )
        let persisted = reloaded.pendingRecovery(for: sessionId)
        XCTAssertEqual(persisted?.attemptCount, 1)
        XCTAssertNotNil(persisted?.lastAttemptAt)
        XCTAssertEqual(persisted?.partialContent, "partial")
    }

    func testUpdatePartialContentPreservesAttemptMetadata() {
        let sessionId = UUID().uuidString

        store.markPending(sessionId: sessionId, partialContent: "partial")
        let started = store.markAttemptStarted(sessionId: sessionId)
        let updated = store.updatePartialContent(sessionId: sessionId, partialContent: "partial continued")

        XCTAssertEqual(updated?.attemptCount, started?.attemptCount)
        XCTAssertEqual(updated?.lastAttemptAt, started?.lastAttemptAt)
        XCTAssertEqual(updated?.partialContent, "partial continued")

        let reloaded = StreamRecoveryStore(
            defaults: defaults,
            notificationCenter: NotificationCenter()
        )
        let persisted = reloaded.pendingRecovery(for: sessionId)
        XCTAssertEqual(persisted?.attemptCount, 1)
        XCTAssertEqual(persisted?.partialContent, "partial continued")
    }

    func testDocumentEditorClearsStaleSubscriptionHandleWhenNoStreamIsActive() {
        XCTAssertTrue(
            DocumentEditorViewModel.shouldClearStaleSubscription(
                activeSubscriptionId: UUID(),
                isStreamActive: false
            )
        )
        XCTAssertFalse(
            DocumentEditorViewModel.shouldClearStaleSubscription(
                activeSubscriptionId: UUID(),
                isStreamActive: true
            )
        )
        XCTAssertFalse(
            DocumentEditorViewModel.shouldClearStaleSubscription(
                activeSubscriptionId: nil,
                isStreamActive: false
            )
        )
    }

    func testDocumentEditorSkipsAssistantAppendWhenMessageAlreadySeen() {
        XCTAssertFalse(
            DocumentEditorViewModel.shouldAppendAssistantSection(
                messageId: "assistant-1",
                content: "Recovered continuation",
                seenMessageIds: ["assistant-1"],
                sections: []
            )
        )
    }

    func testDocumentEditorSkipsAssistantAppendWhenSectionAlreadyExists() {
        let existing = DocumentSection(
            content: AttributedString("Recovered continuation"),
            author: .assistant,
            messageId: "assistant-1"
        )

        XCTAssertFalse(
            DocumentEditorViewModel.shouldAppendAssistantSection(
                messageId: "assistant-1",
                content: "Recovered continuation",
                seenMessageIds: [],
                sections: [existing]
            )
        )
    }

    func testDocumentEditorSkipsFallbackAssistantAppendWhenLatestAssistantMatchesContent() {
        let existing = DocumentSection(
            content: AttributedString("Recovered continuation"),
            author: .assistant
        )

        XCTAssertFalse(
            DocumentEditorViewModel.shouldAppendAssistantSection(
                messageId: nil,
                content: "Recovered continuation",
                seenMessageIds: [],
                sections: [existing]
            )
        )
    }

    func testDocumentEditorAllowsAssistantAppendForNewMessage() {
        XCTAssertTrue(
            DocumentEditorViewModel.shouldAppendAssistantSection(
                messageId: "assistant-2",
                content: "Fresh continuation",
                seenMessageIds: ["assistant-1"],
                sections: []
            )
        )
    }

    func testRecoveryStatusPrefersDraftWarning() {
        let pending = PendingStreamRecovery(
            sessionId: UUID().uuidString,
            createdAt: .distantPast,
            reason: .interruptedStream
        )

        XCTAssertEqual(
            DocumentEditorViewModel.recoveryStatusMessage(
                pendingRecovery: pending,
                hasDraft: true,
                isProcessing: false,
                isStreamActive: false
            ),
            "Recovered response is queued until the draft is cleared."
        )
    }

    func testRecoveryStatusSuppressesBannerDuringActiveRecoveryStream() {
        let pending = PendingStreamRecovery(
            sessionId: UUID().uuidString,
            createdAt: .distantPast,
            reason: .interruptedStream,
            attemptCount: 1,
            lastAttemptAt: .distantPast
        )

        XCTAssertNil(
            DocumentEditorViewModel.recoveryStatusMessage(
                pendingRecovery: pending,
                hasDraft: false,
                isProcessing: true,
                isStreamActive: true
            )
        )
    }

    func testRecoveryStatusRequiresManualRetryAfterCoordinatorLimit() {
        let pending = PendingStreamRecovery(
            sessionId: UUID().uuidString,
            createdAt: .distantPast,
            reason: .interruptedStream,
            attemptCount: StreamRecoveryCoordinator.autoResumeMaxAttempts,
            lastAttemptAt: .distantPast
        )

        XCTAssertEqual(
            DocumentEditorViewModel.recoveryStatusMessage(
                pendingRecovery: pending,
                hasDraft: false,
                isProcessing: false,
                isStreamActive: false
            ),
            "Recovered response needs a manual retry."
        )
    }

    func testShouldAutoResumeUnansweredTurnWhenLastMessageIsUserAndContextExists() {
        XCTAssertTrue(
            DocumentEditorViewModel.shouldAutoResumeUnansweredTurn(
                lastMessageRole: .user,
                messageCount: 2,
                hasCheckpointContext: false
            )
        )
    }

    func testShouldAutoResumeUnansweredTurnWhenCheckpointExistsForSingleUserMessage() {
        XCTAssertTrue(
            DocumentEditorViewModel.shouldAutoResumeUnansweredTurn(
                lastMessageRole: .user,
                messageCount: 1,
                hasCheckpointContext: true
            )
        )
    }

    func testShouldNotAutoResumeWhenLastMessageIsAssistant() {
        XCTAssertFalse(
            DocumentEditorViewModel.shouldAutoResumeUnansweredTurn(
                lastMessageRole: .assistant,
                messageCount: 5,
                hasCheckpointContext: true
            )
        )
    }

    func testShouldNotAutoResumeForSingleUserMessageWithoutContext() {
        XCTAssertFalse(
            DocumentEditorViewModel.shouldAutoResumeUnansweredTurn(
                lastMessageRole: .user,
                messageCount: 1,
                hasCheckpointContext: false
            )
        )
    }

    func testParseAssistantMarkdownPreservesCharactersForFormattedReply() {
        let parsed = DocumentEditorViewModel.parseAssistantMarkdown("**Bold** with `code`")

        XCTAssertEqual(String(parsed.characters), "Bold with code")
    }

    func testStreamingMarkdownCacheRefreshesForSmallMarkdownCueDelta() {
        XCTAssertTrue(
            StreamingSectionView.shouldRefreshMarkdownCache(
                previous: "List intro",
                new: "List intro\n- item"
            )
        )
    }

    func testStreamingMarkdownCacheSkipsTinyPlaintextDelta() {
        XCTAssertFalse(
            StreamingSectionView.shouldRefreshMarkdownCache(
                previous: "Hello",
                new: "Hello there"
            )
        )
    }

    func testStreamingMarkdownCacheRefreshesWhenContentIsReplaced() {
        XCTAssertTrue(
            StreamingSectionView.shouldRefreshMarkdownCache(
                previous: "Partial reply",
                new: "Recovered reply"
            )
        )
    }
}
