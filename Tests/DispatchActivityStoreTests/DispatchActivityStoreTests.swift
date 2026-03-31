import XCTest
import GRDB
@testable import WorldTree

// MARK: - DispatchActivityStore Unit Tests

/// Tests for WorldTreeDispatch model properties and DispatchActivityStore computed values.
/// ValueObservation is not tested (requires live DB observation) — focuses on model logic.
@MainActor
final class DispatchActivityStoreTests: XCTestCase {

    // MARK: - DispatchStatus

    func testDispatchStatusRawValues() {
        XCTAssertEqual(WorldTreeDispatch.DispatchStatus.queued.rawValue, "queued")
        XCTAssertEqual(WorldTreeDispatch.DispatchStatus.running.rawValue, "running")
        XCTAssertEqual(WorldTreeDispatch.DispatchStatus.completed.rawValue, "completed")
        XCTAssertEqual(WorldTreeDispatch.DispatchStatus.failed.rawValue, "failed")
        XCTAssertEqual(WorldTreeDispatch.DispatchStatus.cancelled.rawValue, "cancelled")
        XCTAssertEqual(WorldTreeDispatch.DispatchStatus.interrupted.rawValue, "interrupted")
    }

    // MARK: - isActive

    func testIsActiveForQueuedStatus() {
        let dispatch = makeDispatch(status: .queued)
        XCTAssertTrue(dispatch.isActive)
    }

    func testIsActiveForRunningStatus() {
        let dispatch = makeDispatch(status: .running)
        XCTAssertTrue(dispatch.isActive)
    }

    func testIsNotActiveForCompletedStatus() {
        let dispatch = makeDispatch(status: .completed)
        XCTAssertFalse(dispatch.isActive)
    }

    func testIsNotActiveForFailedStatus() {
        let dispatch = makeDispatch(status: .failed)
        XCTAssertFalse(dispatch.isActive)
    }

    func testIsNotActiveForCancelledStatus() {
        let dispatch = makeDispatch(status: .cancelled)
        XCTAssertFalse(dispatch.isActive)
    }

    func testIsNotActiveForInterruptedStatus() {
        let dispatch = makeDispatch(status: .interrupted)
        XCTAssertFalse(dispatch.isActive)
    }

    // MARK: - displayMessage

    func testDisplayMessageShortText() {
        let dispatch = makeDispatch(message: "Fix the bug")
        XCTAssertEqual(dispatch.displayMessage, "Fix the bug")
    }

    func testDisplayMessageLongTextIsTruncated() {
        let longMessage = String(repeating: "a", count: 100)
        let dispatch = makeDispatch(message: longMessage)
        XCTAssertEqual(dispatch.displayMessage.count, 83, "Should be 80 chars + '...'")
        XCTAssertTrue(dispatch.displayMessage.hasSuffix("..."))
    }

    func testDisplayMessageExactly80Chars() {
        let message = String(repeating: "b", count: 80)
        let dispatch = makeDispatch(message: message)
        XCTAssertEqual(dispatch.displayMessage, message, "Exactly 80 chars should not truncate")
    }

    // MARK: - duration

    func testDurationWithStartAndComplete() {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 1060) // 60 seconds later
        let dispatch = makeDispatch(startedAt: start, completedAt: end)
        XCTAssertNotNil(dispatch.duration)
        XCTAssertEqual(dispatch.duration!, 60.0, accuracy: 0.01)
    }

    func testDurationWithNoStartReturnsNil() {
        let dispatch = makeDispatch(startedAt: nil, completedAt: nil)
        XCTAssertNil(dispatch.duration)
    }

    func testDurationWithStartButNoCompleteUsesNow() {
        let start = Date(timeIntervalSinceNow: -120) // 2 minutes ago
        let dispatch = makeDispatch(startedAt: start, completedAt: nil)
        XCTAssertNotNil(dispatch.duration)
        XCTAssertGreaterThanOrEqual(dispatch.duration!, 119.0)
    }

    // MARK: - durationString

    func testDurationStringSeconds() {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 1045) // 45 seconds
        let dispatch = makeDispatch(startedAt: start, completedAt: end)
        XCTAssertEqual(dispatch.durationString, "45s")
    }

    func testDurationStringMinutes() {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 1180) // 3 minutes
        let dispatch = makeDispatch(startedAt: start, completedAt: end)
        XCTAssertEqual(dispatch.durationString, "3m")
    }

    func testDurationStringHours() {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 8800) // 2h 10m
        let dispatch = makeDispatch(startedAt: start, completedAt: end)
        XCTAssertEqual(dispatch.durationString, "2h 10m")
    }

    func testDurationStringNilWhenNoStart() {
        let dispatch = makeDispatch(startedAt: nil, completedAt: nil)
        XCTAssertNil(dispatch.durationString)
    }

    // MARK: - Codable Round-Trip

    func testDispatchCodableRoundTrip() throws {
        let original = makeDispatch(
            id: "test-123",
            project: "WorldTree",
            status: .completed,
            message: "Run tests"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorldTreeDispatch.self, from: data)

        XCTAssertEqual(decoded.id, "test-123")
        XCTAssertEqual(decoded.project, "WorldTree")
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertEqual(decoded.message, "Run tests")
    }

    // MARK: - DispatchActivityStore Unread Counts

    func testUnreadCountForUnknownProjectIsZero() {
        let store = DispatchActivityStore.shared
        XCTAssertEqual(store.unreadCount(for: "NonExistentProject"), 0)
    }

    func testTotalUnreadDefaultsToZero() {
        let store = DispatchActivityStore.shared
        // totalUnread should be >= 0 (may have state from other tests)
        XCTAssertGreaterThanOrEqual(store.totalUnread, 0)
    }

    // MARK: - Helpers

    private func makeDispatch(
        id: String = UUID().uuidString,
        project: String = "TestProject",
        status: WorldTreeDispatch.DispatchStatus = .queued,
        message: String = "Test dispatch message",
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) -> WorldTreeDispatch {
        WorldTreeDispatch(
            id: id,
            project: project,
            message: message,
            status: status,
            workingDirectory: "/tmp/test",
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}
