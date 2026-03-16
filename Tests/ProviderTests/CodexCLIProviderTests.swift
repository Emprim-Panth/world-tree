import XCTest
@testable import WorldTree

final class CodexCLIProviderTests: XCTestCase {
    func testSkipGitRepoCheckWhenDirectoryIsNotARepository() throws {
        let tempDirectory = try makeTemporaryDirectory(named: "codex-nonrepo")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        XCTAssertTrue(CodexCLIProvider.shouldSkipGitRepoCheck(for: tempDirectory.path))
        XCTAssertFalse(CodexCLIProvider.isInsideGitRepository(tempDirectory.path))
    }

    func testKeepGitRepoCheckInsideRepository() throws {
        let repoRoot = try makeTemporaryDirectory(named: "codex-repo")
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let gitDirectory = repoRoot.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)

        let nestedDirectory = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        XCTAssertFalse(CodexCLIProvider.shouldSkipGitRepoCheck(for: nestedDirectory.path))
        XCTAssertTrue(CodexCLIProvider.isInsideGitRepository(nestedDirectory.path))
    }

    func testMultipleProcessesCanRemainActiveSimultaneously() {
        let provider = CodexCLIProvider()
        let first = Process()
        let second = Process()

        provider.registerActiveProcess(first)
        provider.registerActiveProcess(second)

        XCTAssertEqual(provider.activeProcessCount, 2)
        XCTAssertTrue(provider.isRunning)
        XCTAssertTrue(provider.isCurrentProcess(second))

        provider.unregisterActiveProcess(first)

        XCTAssertEqual(provider.activeProcessCount, 1)
        XCTAssertTrue(provider.isRunning)
        XCTAssertTrue(provider.isCurrentProcess(second))
    }

    func testFinishingNewestProcessFallsBackToPreviousCurrentProcess() {
        let provider = CodexCLIProvider()
        let first = Process()
        let second = Process()

        provider.registerActiveProcess(first)
        provider.registerActiveProcess(second)

        provider.unregisterActiveProcess(second)

        XCTAssertEqual(provider.activeProcessCount, 1)
        XCTAssertTrue(provider.isRunning)
        XCTAssertTrue(provider.isCurrentProcess(first))
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
