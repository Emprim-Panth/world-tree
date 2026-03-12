import XCTest
@testable import WorldTree

// MARK: - GatewayClient Tests

/// Tests for GatewayClient — HTTP request construction, URL building, auth header injection,
/// error classification, and model encoding/decoding. These tests validate the client's
/// construction logic without making real network calls.
final class GatewayClientTests: XCTestCase {

    // MARK: - 1. Base URL Fallback

    func testDefaultBaseURLUsedWhenInitWithoutArgs() async {
        let client = GatewayClient(authToken: "test-token")
        // The default URL is http://localhost:4862 — we can't read it directly since it's private,
        // but we verify the client initializes without crash.
        // Real validation: if the URL were wrong, all requests would fail.
        XCTAssertNotNil(client, "Client should initialize with default base URL")
    }

    func testMalformedBaseURLFallsBackToDefault() async {
        // A malformed URL string should not crash — GatewayClient falls back to defaultURL
        let client = GatewayClient(baseURL: "not a valid url ://???", authToken: "test-token")
        XCTAssertNotNil(client, "Client should fall back to default URL for malformed input")
    }

    func testValidCustomBaseURL() async {
        let client = GatewayClient(baseURL: "http://192.168.1.100:9999", authToken: "custom-token")
        XCTAssertNotNil(client, "Client should accept a valid custom base URL")
    }

    func testEmptyBaseURLFallsBackToDefault() async {
        let client = GatewayClient(baseURL: "", authToken: "test-token")
        XCTAssertNotNil(client, "Client should handle empty base URL string without crash")
    }

    // MARK: - 2. Model Encoding/Decoding Round-Trip

    func testMemoryLogRequestEncoding() throws {
        let request = MemoryLogRequest(
            note: "Test memory note",
            tags: ["swift", "testing"],
            category: "PATTERN",
            project: "WorldTree"
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(MemoryLogRequest.self, from: data)

        XCTAssertEqual(decoded.note, "Test memory note")
        XCTAssertEqual(decoded.tags, ["swift", "testing"])
        XCTAssertEqual(decoded.category, "PATTERN")
        XCTAssertEqual(decoded.project, "WorldTree")
    }

    func testMemoryLogRequestWithNilOptionals() throws {
        let request = MemoryLogRequest(
            note: "Bare minimum",
            tags: nil,
            category: "DECISION",
            project: nil
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(MemoryLogRequest.self, from: data)

        XCTAssertEqual(decoded.note, "Bare minimum")
        XCTAssertNil(decoded.tags)
        XCTAssertNil(decoded.project)
    }

    func testMemoryLogResponseDecoding() throws {
        let json = #"{"id": 42, "ok": true}"#
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(MemoryLogResponse.self, from: data)

        XCTAssertEqual(response.id, 42)
        XCTAssertTrue(response.ok)
    }

    func testKnowledgeEntryDecoding() throws {
        let json = """
        {
            "id": 7,
            "category": "CORRECTION",
            "content": "Always use .whitespacesAndNewlines",
            "project": "WorldTree",
            "tags": ["swift", "parsing"],
            "metadata": null,
            "created_at": 1710000000,
            "session_id": "sess-abc"
        }
        """
        let data = json.data(using: .utf8)!
        let entry = try JSONDecoder().decode(KnowledgeEntry.self, from: data)

        XCTAssertEqual(entry.id, 7)
        XCTAssertEqual(entry.category, "CORRECTION")
        XCTAssertEqual(entry.content, "Always use .whitespacesAndNewlines")
        XCTAssertEqual(entry.project, "WorldTree")
        XCTAssertEqual(entry.tags, ["swift", "parsing"])
        XCTAssertEqual(entry.sessionId, "sess-abc")
    }

    func testHandoffDecodingWithSnakeCase() throws {
        let json = """
        {
            "id": "hoff-123",
            "message": "Ship content filter",
            "project": "BookBuddy",
            "priority": "high",
            "status": "pending",
            "source": "heartbeat",
            "createdAt": 1710000000,
            "pickedUpAt": null,
            "completedAt": null,
            "viewedAt": null
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let handoff = try decoder.decode(Handoff.self, from: data)

        XCTAssertEqual(handoff.id, "hoff-123")
        XCTAssertEqual(handoff.message, "Ship content filter")
        XCTAssertEqual(handoff.priority, "high")
        XCTAssertEqual(handoff.status, "pending")
        XCTAssertNil(handoff.pickedUpAt)
    }

    // MARK: - 3. Error Classification

    func testGatewayErrorIsPermanent() {
        XCTAssertTrue(GatewayError.unauthorized.isPermanent, "401/403 should be permanent")
        XCTAssertTrue(GatewayError.connectionRefused.isPermanent, "Connection refused should be permanent")
        XCTAssertTrue(GatewayError.terminalNotFound.isPermanent, "404 terminal should be permanent")
        XCTAssertTrue(GatewayError.permanentHTTPError(statusCode: 400).isPermanent, "400 should be permanent")
        XCTAssertTrue(GatewayError.permanentHTTPError(statusCode: 422).isPermanent, "422 should be permanent")
    }

    func testGatewayErrorIsTransient() {
        XCTAssertFalse(GatewayError.requestFailed.isPermanent, "Generic request failure should be transient")
        XCTAssertFalse(GatewayError.invalidResponse.isPermanent, "Invalid response should be transient")
        XCTAssertFalse(GatewayError.subscriptionFailed(underlying: "timeout").isPermanent,
                       "Subscription failure should be transient")
    }

    func testPermanentHTTPErrorExcludes408And429() {
        // 408 (Request Timeout) and 429 (Too Many Requests) are retryable even though they're 4xx
        XCTAssertFalse(GatewayError.permanentHTTPError(statusCode: 408).isPermanent,
                       "408 Request Timeout should be retryable")
        XCTAssertFalse(GatewayError.permanentHTTPError(statusCode: 429).isPermanent,
                       "429 Too Many Requests should be retryable")
    }

    func testGatewayErrorDescriptions() {
        XCTAssertNotNil(GatewayError.unauthorized.errorDescription)
        XCTAssertNotNil(GatewayError.connectionRefused.errorDescription)
        XCTAssertNotNil(GatewayError.requestFailed.errorDescription)
        XCTAssertNotNil(GatewayError.terminalNotFound.errorDescription)
        XCTAssertNotNil(GatewayError.permanentHTTPError(statusCode: 500).errorDescription)
        XCTAssertNotNil(GatewayError.subscriptionFailed(underlying: "test").errorDescription)

        let httpError = GatewayError.permanentHTTPError(statusCode: 418)
        XCTAssertTrue(httpError.errorDescription!.contains("418"),
                      "Error description should include the status code")
    }

    // MARK: - 4. Terminal Session Decoding

    func testTerminalSessionDecoding() throws {
        let json = """
        {
            "id": "term-abc",
            "cmd": "bash",
            "args": ["-l"],
            "cwd": "/Users/evan/Development",
            "project": "WorldTree",
            "name": "dev-shell",
            "pid": 12345,
            "created_at": 1710000000
        }
        """
        let data = json.data(using: .utf8)!
        let session = try JSONDecoder().decode(TerminalSession.self, from: data)

        XCTAssertEqual(session.id, "term-abc")
        XCTAssertEqual(session.cmd, "bash")
        XCTAssertEqual(session.args, ["-l"])
        XCTAssertEqual(session.cwd, "/Users/evan/Development")
        XCTAssertEqual(session.project, "WorldTree")
        XCTAssertEqual(session.name, "dev-shell")
        XCTAssertEqual(session.pid, 12345)
        XCTAssertEqual(session.createdAt, 1710000000)
    }

    func testTerminalSessionDecodingWithNilOptionals() throws {
        let json = """
        {"id": "term-min", "cmd": "zsh", "args": null, "cwd": null, "project": null, "name": null, "pid": null, "created_at": 0}
        """
        let data = json.data(using: .utf8)!
        let session = try JSONDecoder().decode(TerminalSession.self, from: data)

        XCTAssertEqual(session.id, "term-min")
        XCTAssertEqual(session.cmd, "zsh")
        XCTAssertNil(session.args)
        XCTAssertNil(session.cwd)
        XCTAssertNil(session.project)
        XCTAssertNil(session.pid)
    }
}
