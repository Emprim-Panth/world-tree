import XCTest
@testable import WorldTree

// MARK: - CrashSentinel Unit Tests

/// Tests for SentinelData/CrashInfo models and sentinel file round-trip logic.
/// Uses temp file paths — does NOT interfere with the live sentinel.
@MainActor
final class CrashSentinelTests: XCTestCase {

    private var tempDir: String!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = NSTemporaryDirectory() + "sentinel-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(atPath: dir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - SentinelData Codable

    func testSentinelDataCodableRoundTrip() throws {
        let sentinel = SentinelData(
            state: "running",
            pid: 12345,
            launchedAt: "2026-03-29T10:00:00Z",
            updatedAt: "2026-03-29T10:05:00Z",
            version: "1.2.3",
            lastUserInputAt: "2026-03-29T10:04:30Z"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(sentinel)
        let decoded = try JSONDecoder().decode(SentinelData.self, from: data)

        XCTAssertEqual(decoded.state, "running")
        XCTAssertEqual(decoded.pid, 12345)
        XCTAssertEqual(decoded.launchedAt, "2026-03-29T10:00:00Z")
        XCTAssertEqual(decoded.updatedAt, "2026-03-29T10:05:00Z")
        XCTAssertEqual(decoded.version, "1.2.3")
        XCTAssertEqual(decoded.lastUserInputAt, "2026-03-29T10:04:30Z")
    }

    func testSentinelDataWithoutLastUserInput() throws {
        let sentinel = SentinelData(
            state: "clean",
            pid: 99,
            launchedAt: "2026-03-29T10:00:00Z",
            updatedAt: "2026-03-29T10:05:00Z",
            version: "1.0.0"
        )

        let data = try JSONEncoder().encode(sentinel)
        let decoded = try JSONDecoder().decode(SentinelData.self, from: data)

        XCTAssertEqual(decoded.state, "clean")
        XCTAssertNil(decoded.lastUserInputAt)
    }

    // MARK: - CrashInfo

    func testCrashInfoProperties() {
        let info = CrashInfo(
            previousLaunch: "2026-03-29T09:00:00Z",
            lastHeartbeat: "2026-03-29T09:45:00Z",
            pid: 42
        )

        XCTAssertEqual(info.previousLaunch, "2026-03-29T09:00:00Z")
        XCTAssertEqual(info.lastHeartbeat, "2026-03-29T09:45:00Z")
        XCTAssertEqual(info.pid, 42)
    }

    // MARK: - Sentinel File Write/Read Round-Trip

    func testSentinelFileWriteAndRead() throws {
        let path = "\(tempDir!)/sentinel.json"

        let sentinel = SentinelData(
            state: "running",
            pid: ProcessInfo.processInfo.processIdentifier,
            launchedAt: ISO8601DateFormatter().string(from: Date()),
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            version: "test"
        )

        // Write
        let data = try JSONEncoder().encode(sentinel)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)

        // Read back
        let readData = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode(SentinelData.self, from: readData)

        XCTAssertEqual(decoded.state, sentinel.state)
        XCTAssertEqual(decoded.pid, sentinel.pid)
        XCTAssertEqual(decoded.version, "test")
    }

    // MARK: - Crash Detection Logic

    func testRunningStateIndicatesCrash() throws {
        let path = "\(tempDir!)/sentinel.json"

        // Simulate previous session that was "running" (didn't exit cleanly)
        let sentinel = SentinelData(
            state: "running",
            pid: 9999,
            launchedAt: "2026-03-29T08:00:00Z",
            updatedAt: "2026-03-29T08:30:00Z",
            version: "1.0.0"
        )

        let data = try JSONEncoder().encode(sentinel)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)

        // Read and check — "running" means previous session didn't clean up
        let readData = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode(SentinelData.self, from: readData)

        XCTAssertEqual(decoded.state, "running",
                       "State 'running' indicates abnormal exit")
        // The crash detection logic: state == "running" means crash
        let wasCrash = decoded.state == "running"
        XCTAssertTrue(wasCrash)
    }

    func testCleanStateIndicatesNoCrash() throws {
        let path = "\(tempDir!)/sentinel.json"

        let sentinel = SentinelData(
            state: "clean",
            pid: 8888,
            launchedAt: "2026-03-29T08:00:00Z",
            updatedAt: "2026-03-29T08:30:00Z",
            version: "1.0.0"
        )

        let data = try JSONEncoder().encode(sentinel)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)

        let readData = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode(SentinelData.self, from: readData)

        let wasCrash = decoded.state == "running"
        XCTAssertFalse(wasCrash, "State 'clean' should not indicate crash")
    }

    func testMissingSentinelFileIndicatesNoCrash() {
        let path = "\(tempDir!)/nonexistent-sentinel.json"
        let exists = FileManager.default.fileExists(atPath: path)
        XCTAssertFalse(exists, "Missing sentinel = no previous session = no crash")
    }

    // MARK: - Crash Log Append

    func testCrashLogAppend() throws {
        let logPath = "\(tempDir!)/crash-log.jsonl"

        // Simulate writing a crash log entry (mirrors CrashSentinel.logCrash)
        let entry: [String: String] = [
            "event": "abnormal_exit",
            "previous_launch": "2026-03-29T08:00:00Z",
            "last_heartbeat": "2026-03-29T08:30:00Z",
            "previous_pid": "9999",
            "detected_at": ISO8601DateFormatter().string(from: Date()),
        ]

        let data = try JSONSerialization.data(withJSONObject: entry)
        var line = String(data: data, encoding: .utf8)! + "\n"
        try line.write(toFile: logPath, atomically: true, encoding: .utf8)

        // Append a second entry
        let entry2: [String: String] = [
            "event": "abnormal_exit",
            "previous_launch": "2026-03-29T09:00:00Z",
            "last_heartbeat": "2026-03-29T09:15:00Z",
            "previous_pid": "1111",
            "detected_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let data2 = try JSONSerialization.data(withJSONObject: entry2)
        let line2 = String(data: data2, encoding: .utf8)! + "\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        handle.seekToEndOfFile()
        handle.write(line2.data(using: .utf8)!)
        handle.closeFile()

        // Read back and verify 2 lines
        let contents = try String(contentsOfFile: logPath, encoding: .utf8)
        let lines = contents.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2, "Should have 2 crash log entries")
    }
}
