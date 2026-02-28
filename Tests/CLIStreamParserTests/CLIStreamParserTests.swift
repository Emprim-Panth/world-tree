import XCTest
@testable import WorldTree

// MARK: - CLIStreamParser Tests

/// Tests for CLIStreamParser — the line-buffered JSON parser that converts Claude CLI
/// `--output-format stream-json` events into BridgeEvent values for the UI layer.
/// Covers line buffering, partial reads, flush behavior, and all event type mappings.
final class CLIStreamParserTests: XCTestCase {

    private var parser: CLIStreamParser!

    override func setUp() {
        super.setUp()
        parser = CLIStreamParser()
    }

    override func tearDown() {
        parser = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Build a single JSON line terminated with newline.
    private func jsonLine(_ dict: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8)! + "\n"
    }

    // MARK: - 1. testFeedPartialLine

    func testFeedPartialLine() {
        // Feed data without a trailing newline — no complete line, so no events yet
        let partial = "{\"type\":\"system\",\"subtype\":\"init\",\"sessionId\":\"abc123\""
        let events1 = parser.feed(partial)
        XCTAssertTrue(events1.isEmpty, "Partial line (no newline) should not produce any events")

        // Complete the line with closing brace + newline
        let rest = "}\n"
        let events2 = parser.feed(rest)
        // system/init doesn't emit a BridgeEvent (it's internal), but sessionId should be captured
        XCTAssertTrue(events2.isEmpty, "system/init event should not emit BridgeEvent")
        XCTAssertEqual(parser.cliSessionId, "abc123", "Session ID should be captured from completed system/init line")
    }

    // MARK: - 2. testFeedMultipleLines

    func testFeedMultipleLines() {
        // Two complete JSON lines in a single feed() call
        let line1 = jsonLine([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "Hello"]
            ] as [String: Any]
        ])
        let line2 = jsonLine([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": " world"]
            ] as [String: Any]
        ])

        let events = parser.feed(line1 + line2)
        XCTAssertEqual(events.count, 2, "Two complete JSON lines should produce two events")

        if case .text(let t1) = events[0] {
            XCTAssertEqual(t1, "Hello")
        } else {
            XCTFail("First event should be .text(\"Hello\")")
        }

        if case .text(let t2) = events[1] {
            XCTAssertEqual(t2, " world")
        } else {
            XCTFail("Second event should be .text(\" world\")")
        }
    }

    // MARK: - 3. testFlushRemainingBuffer

    func testFlushRemainingBuffer() {
        // Feed a text delta without trailing newline
        let incomplete = jsonLine([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "flushed"]
            ] as [String: Any]
        ]).trimmingCharacters(in: .newlines) // Remove trailing newline to simulate incomplete read

        let feedEvents = parser.feed(incomplete)
        XCTAssertTrue(feedEvents.isEmpty, "No newline means no events from feed()")

        let flushEvents = parser.flush()
        XCTAssertEqual(flushEvents.count, 1, "flush() should process the remaining buffer")

        if case .text(let text) = flushEvents[0] {
            XCTAssertEqual(text, "flushed")
        } else {
            XCTFail("Flushed event should be .text(\"flushed\")")
        }
    }

    // MARK: - 4. testTextEvent

    func testTextEvent() {
        // Feed a content_block_delta with text_delta — should produce .text
        let line = jsonLine([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "SwiftUI is declarative."]
            ] as [String: Any]
        ])

        let events = parser.feed(line)
        XCTAssertEqual(events.count, 1)

        if case .text(let content) = events[0] {
            XCTAssertEqual(content, "SwiftUI is declarative.")
        } else {
            XCTFail("Expected .text event, got something else")
        }
    }

    // MARK: - 5. testToolStartAndEnd

    func testToolStartAndEnd() {
        // Step 1: content_block_start with tool_use
        let blockStart = jsonLine([
            "type": "stream_event",
            "event": [
                "type": "content_block_start",
                "content_block": [
                    "type": "tool_use",
                    "name": "bash",
                    "id": "tool_abc123"
                ] as [String: Any]
            ] as [String: Any]
        ])

        let startEvents = parser.feed(blockStart)
        XCTAssertTrue(startEvents.isEmpty, "content_block_start should not emit events (deferred until stop)")

        // Step 2: input_json_delta with partial JSON
        let inputDelta1 = jsonLine([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "input_json_delta", "partial_json": "{\"command\":"]
            ] as [String: Any]
        ])
        let inputDelta2 = jsonLine([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "input_json_delta", "partial_json": "\"ls -la\"}"]
            ] as [String: Any]
        ])

        let deltaEvents1 = parser.feed(inputDelta1)
        let deltaEvents2 = parser.feed(inputDelta2)
        XCTAssertTrue(deltaEvents1.isEmpty, "input_json_delta should not emit events (accumulated)")
        XCTAssertTrue(deltaEvents2.isEmpty, "input_json_delta should not emit events (accumulated)")

        // Step 3: content_block_stop — this should emit .toolStart with accumulated input
        let blockStop = jsonLine([
            "type": "stream_event",
            "event": ["type": "content_block_stop"] as [String: Any]
        ])

        let stopEvents = parser.feed(blockStop)
        XCTAssertEqual(stopEvents.count, 1, "content_block_stop should emit .toolStart")

        if case .toolStart(let name, let input) = stopEvents[0] {
            XCTAssertEqual(name, "bash")
            XCTAssertEqual(input, "{\"command\":\"ls -la\"}", "Input should be fully accumulated JSON")
        } else {
            XCTFail("Expected .toolStart event at content_block_stop")
        }

        // Step 4: tool result event — should emit .toolEnd
        let toolResult = jsonLine([
            "type": "tool",
            "name": "bash",
            "content": "file1.txt\nfile2.txt",
            "is_error": false
        ] as [String: Any])

        let toolEvents = parser.feed(toolResult)
        XCTAssertEqual(toolEvents.count, 1)

        if case .toolEnd(let name, let result, let isError) = toolEvents[0] {
            XCTAssertEqual(name, "bash")
            XCTAssertEqual(result, "file1.txt\nfile2.txt")
            XCTAssertFalse(isError)
        } else {
            XCTFail("Expected .toolEnd event")
        }
    }

    // MARK: - 6. testResultEvent

    func testResultEvent() {
        // Result event should NOT emit a BridgeEvent (provider emits .done on process termination)
        // but should capture cost, usage, and metadata
        let line = jsonLine([
            "type": "result",
            "num_turns": 3,
            "cost_usd": 0.042,
            "session_id": "sess-result-456",
            "is_error": false,
            "usage": [
                "input_tokens": 2500,
                "output_tokens": 1200
            ] as [String: Any]
        ] as [String: Any])

        let events = parser.feed(line)
        XCTAssertTrue(events.isEmpty, "result event should not emit BridgeEvent (provider handles .done)")

        // Verify captured metadata
        XCTAssertEqual(parser.numTurns, 3)
        XCTAssertEqual(parser.costUSD, 0.042, accuracy: 0.001)
        XCTAssertEqual(parser.cliSessionId, "sess-result-456")
        XCTAssertFalse(parser.isError)
        XCTAssertEqual(parser.inputTokens, 2500)
        XCTAssertEqual(parser.outputTokens, 1200)
    }

    // MARK: - 7. testSessionIdCapture

    func testSessionIdCapture() {
        // Session ID should be nil before any events
        XCTAssertNil(parser.cliSessionId)

        // system/init sets sessionId
        let systemInit = jsonLine([
            "type": "system",
            "subtype": "init",
            "sessionId": "init-session-789"
        ])

        _ = parser.feed(systemInit)
        XCTAssertEqual(parser.cliSessionId, "init-session-789")

        // session_id from top-level JSON field (any event type) should also be captured
        let hookEvent = jsonLine([
            "type": "hook_started",
            "session_id": "hook-session-012"
        ])

        _ = parser.feed(hookEvent)
        XCTAssertEqual(parser.cliSessionId, "hook-session-012",
                       "session_id from any event should update cliSessionId")

        // assistant event with session_id should override
        let assistantEvent = jsonLine([
            "type": "assistant",
            "session_id": "assistant-session-345",
            "message": [
                "role": "assistant",
                "content": [] as [Any]
            ] as [String: Any]
        ] as [String: Any])

        _ = parser.feed(assistantEvent)
        XCTAssertEqual(parser.cliSessionId, "assistant-session-345",
                       "assistant event session_id should update cliSessionId")
    }

    // MARK: - 8. testInvalidJSON

    func testInvalidJSON() {
        // Garbage data should not crash and should produce no events
        let garbage = "this is not json at all\n"
        let events1 = parser.feed(garbage)
        XCTAssertTrue(events1.isEmpty, "Garbage input should produce no events")

        // Malformed JSON (missing closing brace)
        let malformed = "{\"type\": \"system\", \"subtype\": \"init\"\n"
        let events2 = parser.feed(malformed)
        XCTAssertTrue(events2.isEmpty, "Malformed JSON should produce no events")

        // Empty line
        let empty = "\n"
        let events3 = parser.feed(empty)
        XCTAssertTrue(events3.isEmpty, "Empty line should produce no events")

        // JSON without "type" field
        let noType = "{\"data\": \"something\"}\n"
        let events4 = parser.feed(noType)
        XCTAssertTrue(events4.isEmpty, "JSON without 'type' field should produce no events")

        // Verify parser is still functional after all garbage
        let valid = jsonLine([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "recovered"]
            ] as [String: Any]
        ])
        let recovered = parser.feed(valid)
        XCTAssertEqual(recovered.count, 1, "Parser should recover and process valid JSON after garbage")
        if case .text(let t) = recovered[0] {
            XCTAssertEqual(t, "recovered")
        } else {
            XCTFail("Expected .text event after recovery")
        }
    }

    // MARK: - Additional Coverage

    func testFlushEmptyBuffer() {
        // flush() on a brand-new parser with nothing buffered
        let events = parser.flush()
        XCTAssertTrue(events.isEmpty, "flush() on empty buffer should return no events")
    }

    func testFeedDataOverload() {
        // Test the Data-based feed() overload
        let line = jsonLine([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "data-overload"]
            ] as [String: Any]
        ])
        let data = line.data(using: .utf8)!

        let events = parser.feed(data)
        XCTAssertEqual(events.count, 1)
        if case .text(let t) = events[0] {
            XCTAssertEqual(t, "data-overload")
        } else {
            XCTFail("Expected .text from Data overload")
        }
    }

    func testToolEndWithError() {
        // tool event with is_error = true
        let line = jsonLine([
            "type": "tool",
            "name": "read_file",
            "content": "Error: file not found: /nonexistent/path.swift",
            "is_error": true
        ] as [String: Any])

        let events = parser.feed(line)
        XCTAssertEqual(events.count, 1)

        if case .toolEnd(let name, let result, let isError) = events[0] {
            XCTAssertEqual(name, "read_file")
            XCTAssertTrue(result.contains("file not found"))
            XCTAssertTrue(isError, "is_error should be true")
        } else {
            XCTFail("Expected .toolEnd event with error")
        }
    }

    func testToolEndContentTruncation() {
        // Tool content longer than 200 chars should be truncated with "..."
        let longContent = String(repeating: "x", count: 300)
        let line = jsonLine([
            "type": "tool",
            "name": "read_file",
            "content": longContent,
            "is_error": false
        ] as [String: Any])

        let events = parser.feed(line)
        XCTAssertEqual(events.count, 1)

        if case .toolEnd(_, let result, _) = events[0] {
            XCTAssertTrue(result.hasSuffix("..."), "Long content should be truncated with ellipsis")
            XCTAssertEqual(result.count, 203, "Truncated content should be 200 chars + '...'")
        } else {
            XCTFail("Expected .toolEnd event")
        }
    }

    func testAssistantFallbackEmitsTextWhenNoStreaming() {
        // When no stream_event text deltas preceded the assistant event,
        // the assistant fallback should emit the full text
        let line = jsonLine([
            "type": "assistant",
            "session_id": "sess-fallback",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "Full response text here."]
                ]
            ] as [String: Any]
        ] as [String: Any])

        let events = parser.feed(line)
        XCTAssertEqual(events.count, 1, "Assistant fallback should emit text when no streaming occurred")

        if case .text(let content) = events[0] {
            XCTAssertEqual(content, "Full response text here.")
        } else {
            XCTFail("Expected .text from assistant fallback")
        }
    }

    func testAssistantFallbackSkipsTextWhenAlreadyStreamed() {
        // First, stream some text via stream_event
        let streamLine = jsonLine([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "streamed chunk"]
            ] as [String: Any]
        ])
        _ = parser.feed(streamLine)

        // Now the assistant event arrives with full text — should NOT emit duplicate
        let assistantLine = jsonLine([
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "streamed chunk and more"]
                ]
            ] as [String: Any]
        ] as [String: Any])

        let events = parser.feed(assistantLine)
        // No text events should be emitted (hasEmittedText is true)
        let textEvents = events.filter { if case .text = $0 { return true }; return false }
        XCTAssertTrue(textEvents.isEmpty, "Assistant fallback should skip text when streaming already emitted it")
    }

    func testAssistantFallbackEmitsToolStartForUnseenTools() {
        // Assistant event with a tool_use block that was NOT preceded by stream_event
        let line = jsonLine([
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "name": "read_file",
                        "id": "tool_fallback_001",
                        "input": ["path": "/tmp/test.swift"]
                    ] as [String: Any]
                ]
            ] as [String: Any]
        ] as [String: Any])

        let events = parser.feed(line)
        XCTAssertEqual(events.count, 1, "Assistant fallback should emit .toolStart for unseen tool_use blocks")

        if case .toolStart(let name, _) = events[0] {
            XCTAssertEqual(name, "read_file")
        } else {
            XCTFail("Expected .toolStart from assistant fallback")
        }
    }

    func testResultWithTotalCostUSD() {
        // Some CLI versions use "total_cost_usd" instead of "cost_usd"
        let line = jsonLine([
            "type": "result",
            "num_turns": 1,
            "total_cost_usd": 0.015,
            "is_error": false,
            "usage": [
                "input_tokens": 500,
                "output_tokens": 200
            ] as [String: Any]
        ] as [String: Any])

        _ = parser.feed(line)
        XCTAssertEqual(parser.costUSD, 0.015, accuracy: 0.001,
                       "Parser should accept total_cost_usd as fallback for cost_usd")
    }

    func testResultWithError() {
        let line = jsonLine([
            "type": "result",
            "num_turns": 0,
            "cost_usd": 0.0,
            "is_error": true,
            "session_id": "err-session"
        ] as [String: Any])

        _ = parser.feed(line)
        XCTAssertTrue(parser.isError, "isError should be true when result reports an error")
        XCTAssertEqual(parser.numTurns, 0)
    }

    func testInternalEventsProduceNoOutput() {
        // message_start, message_delta, message_stop, ping — all internal SSE lifecycle events
        let internalTypes = ["message_start", "message_delta", "message_stop", "ping"]

        for eventType in internalTypes {
            let line = jsonLine([
                "type": "stream_event",
                "event": ["type": eventType] as [String: Any]
            ])
            let events = parser.feed(line)
            XCTAssertTrue(events.isEmpty, "\(eventType) should not produce any BridgeEvent")
        }
    }

    func testUnknownTopLevelTypeIgnored() {
        // Unknown event types at the top level should be silently ignored
        let line = jsonLine([
            "type": "unknown_future_event",
            "data": "something"
        ])
        let events = parser.feed(line)
        XCTAssertTrue(events.isEmpty, "Unknown top-level type should produce no events")
    }
}
