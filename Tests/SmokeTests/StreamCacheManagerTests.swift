import XCTest
@testable import WorldTree

final class StreamCacheManagerTests: XCTestCase {

    private func streamFilePath(for sessionId: String) -> String {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return cachesDir
            .appendingPathComponent("WorldTree")
            .appendingPathComponent("streams")
            .appendingPathComponent("\(sessionId).tmp")
            .path
    }

    func testAppendCreatesRecoveryFileWithoutExplicitOpen() async {
        let sessionId = "stream-cache-append-\(UUID().uuidString)"
        await StreamCacheManager.shared.closeStream(sessionId: sessionId)

        await StreamCacheManager.shared.appendToStream(sessionId: sessionId, chunk: "hello")
        let recovered = await StreamCacheManager.shared.recoverOrphanedStreams()

        XCTAssertEqual(recovered[sessionId], "hello")
    }

    func testTouchCreatesRecoveryFileForNonTextActivity() async {
        let sessionId = "stream-cache-touch-\(UUID().uuidString)"
        await StreamCacheManager.shared.closeStream(sessionId: sessionId)

        await StreamCacheManager.shared.touchStream(sessionId: sessionId)

        XCTAssertTrue(FileManager.default.fileExists(atPath: streamFilePath(for: sessionId)))

        let recovered = await StreamCacheManager.shared.recoverOrphanedStreams()

        XCTAssertEqual(recovered[sessionId], "")
    }

    func testCloseStreamRemovesRecoveryFile() async {
        let sessionId = "stream-cache-close-\(UUID().uuidString)"

        await StreamCacheManager.shared.appendToStream(sessionId: sessionId, chunk: "cleanup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: streamFilePath(for: sessionId)))

        await StreamCacheManager.shared.closeStream(sessionId: sessionId)

        XCTAssertFalse(FileManager.default.fileExists(atPath: streamFilePath(for: sessionId)))
    }
}
