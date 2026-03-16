import XCTest
@testable import WorldTree

final class StreamCancellationTests: XCTestCase {
    private func streamFilePath(for sessionId: String) -> String {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return cachesDir
            .appendingPathComponent("WorldTree")
            .appendingPathComponent("streams")
            .appendingPathComponent("\(sessionId).tmp")
            .path
    }

    func testCloseStreamIsIdempotentAfterRepeatedCancellationCleanup() async {
        let sessionId = "stream-cancel-\(UUID().uuidString)"

        await StreamCacheManager.shared.appendToStream(sessionId: sessionId, chunk: "partial")
        XCTAssertTrue(FileManager.default.fileExists(atPath: streamFilePath(for: sessionId)))

        await StreamCacheManager.shared.closeStream(sessionId: sessionId)
        await StreamCacheManager.shared.closeStream(sessionId: sessionId)

        XCTAssertFalse(FileManager.default.fileExists(atPath: streamFilePath(for: sessionId)))
    }
}
