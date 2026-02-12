import Foundation

// MARK: - CLI Stream Parser

/// Line-buffered JSON parser that maps Claude CLI `--output-format stream-json` events
/// to `BridgeEvent` for UI consumption.
///
/// CLI event types:
/// - `system` (init) → internal: capture session ID
/// - `stream_event` (content_block_delta/text_delta) → `.text(chunk)`
/// - `stream_event` (content_block_start/tool_use) → `.toolStart(name, input)`
/// - `tool` (name, content, is_error) → `.toolEnd(name, result, isError)`
/// - `assistant` (full turn) → fallback `.toolStart()` if no stream_event preceded it
/// - `result` (final) → internal: capture cost/usage
final class CLIStreamParser {
    /// CLI session ID captured from the `system/init` event
    private(set) var cliSessionId: String?

    /// Accumulated cost from `result` events (CLI reports cost_usd, not token counts)
    private(set) var costUSD: Double = 0

    /// Number of turns from `result` events
    private(set) var numTurns: Int = 0

    /// Whether the CLI reported an error in the final result
    private(set) var isError: Bool = false

    /// Track tool_use IDs we've already emitted `.toolStart` for via stream_event,
    /// so we don't duplicate from the `assistant` fallback.
    /// Using IDs (not names) handles multiple calls to the same tool in one turn.
    private var emittedToolIds: Set<String> = []
    private var currentToolId: String?
    private var currentToolName: String?

    /// Incomplete line buffer for handling partial reads
    private var lineBuffer = ""

    // MARK: - Public API

    /// Feed raw data from the CLI process stdout.
    /// Returns an array of BridgeEvents parsed from complete lines.
    func feed(_ data: Data) -> [BridgeEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return feed(text)
    }

    /// Feed a text chunk from the CLI process stdout.
    func feed(_ text: String) -> [BridgeEvent] {
        lineBuffer += text
        var events: [BridgeEvent] = []

        // Process complete lines
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let parsed = parseLine(trimmed) {
                events.append(contentsOf: parsed)
            }
        }

        return events
    }

    /// Flush any remaining buffered data (call when process terminates).
    func flush() -> [BridgeEvent] {
        guard !lineBuffer.isEmpty else { return [] }
        let remaining = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        lineBuffer = ""
        guard !remaining.isEmpty else { return [] }
        return parseLine(remaining) ?? []
    }

    // MARK: - Line Parsing

    private func parseLine(_ line: String) -> [BridgeEvent]? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "system":
            return parseSystem(json)
        case "stream_event":
            return parseStreamEvent(json)
        case "assistant":
            return parseAssistant(json)
        case "tool":
            return parseTool(json)
        case "result":
            return parseResult(json)
        default:
            return nil
        }
    }

    // MARK: - Event Handlers

    /// `{"type":"system","subtype":"init","sessionId":"...","cwd":"...","model":"..."}`
    private func parseSystem(_ json: [String: Any]) -> [BridgeEvent]? {
        if let subtype = json["subtype"] as? String, subtype == "init" {
            cliSessionId = json["sessionId"] as? String
                ?? json["session_id"] as? String
        }
        return nil // Internal event, no BridgeEvent emitted
    }

    /// `{"type":"stream_event","event":{"event":"content_block_delta","data":{...}}}`
    private func parseStreamEvent(_ json: [String: Any]) -> [BridgeEvent]? {
        guard let eventWrapper = json["event"] as? [String: Any],
              let eventType = eventWrapper["event"] as? String,
              let eventData = eventWrapper["data"] as? [String: Any] else {
            return nil
        }

        switch eventType {
        case "content_block_start":
            return parseContentBlockStart(eventData)
        case "content_block_delta":
            return parseContentBlockDelta(eventData)
        case "content_block_stop":
            currentToolName = nil
            currentToolId = nil
            return nil
        case "message_start", "message_delta", "message_stop", "ping":
            return nil // Internal SSE lifecycle events
        default:
            return nil
        }
    }

    /// content_block_start: detect tool_use blocks to emit `.toolStart`
    private func parseContentBlockStart(_ data: [String: Any]) -> [BridgeEvent]? {
        guard let contentBlock = data["content_block"] as? [String: Any],
              let blockType = contentBlock["type"] as? String else {
            return nil
        }

        if blockType == "tool_use" {
            let name = contentBlock["name"] as? String ?? "unknown"
            let id = contentBlock["id"] as? String ?? UUID().uuidString
            currentToolName = name
            currentToolId = id
            emittedToolIds.insert(id)
            return [.toolStart(name: name, input: "{}")]
        }

        return nil
    }

    /// content_block_delta: text chunks or input_json chunks
    private func parseContentBlockDelta(_ data: [String: Any]) -> [BridgeEvent]? {
        guard let delta = data["delta"] as? [String: Any],
              let deltaType = delta["type"] as? String else {
            return nil
        }

        switch deltaType {
        case "text_delta":
            if let text = delta["text"] as? String, !text.isEmpty {
                return [.text(text)]
            }
        case "input_json_delta":
            // Tool input streaming — we already emitted toolStart, input accumulates on CLI side
            return nil
        default:
            break
        }

        return nil
    }

    /// `{"type":"assistant","message":{"role":"assistant","content":[...]},"session_id":"..."}`
    /// Fallback: if we missed stream_event for a tool_use, emit toolStart here.
    private func parseAssistant(_ json: [String: Any]) -> [BridgeEvent]? {
        // Update session ID if present
        if let sid = json["session_id"] as? String {
            cliSessionId = sid
        }

        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return nil
        }

        var events: [BridgeEvent] = []

        for block in content {
            guard let blockType = block["type"] as? String else { continue }

            if blockType == "tool_use" {
                let name = block["name"] as? String ?? "unknown"
                let id = block["id"] as? String ?? ""
                // Only emit if we didn't already emit via stream_event (check by ID)
                if !id.isEmpty && !emittedToolIds.contains(id) {
                    let inputJSON: String
                    if let input = block["input"],
                       let inputData = try? JSONSerialization.data(withJSONObject: input),
                       let inputStr = String(data: inputData, encoding: .utf8) {
                        inputJSON = inputStr
                    } else {
                        inputJSON = "{}"
                    }
                    events.append(.toolStart(name: name, input: inputJSON))
                }
            }
        }

        // Clear emitted tool IDs — this assistant turn is complete
        emittedToolIds.removeAll()

        return events.isEmpty ? nil : events
    }

    /// `{"type":"tool","name":"read_file","content":"...","is_error":false}`
    private func parseTool(_ json: [String: Any]) -> [BridgeEvent]? {
        let name = json["name"] as? String ?? "unknown"
        let content = json["content"] as? String ?? ""
        let isError = json["is_error"] as? Bool ?? false

        // Truncate content for the UI event (full content stays on CLI side)
        let displayContent = content.count > 200 ? String(content.prefix(200)) + "..." : content

        return [.toolEnd(name: name, result: displayContent, isError: isError)]
    }

    /// `{"type":"result","num_turns":1,"cost_usd":0.01,"session_id":"...","is_error":false}`
    private func parseResult(_ json: [String: Any]) -> [BridgeEvent]? {
        numTurns = json["num_turns"] as? Int ?? 0
        costUSD = json["cost_usd"] as? Double ?? 0
        isError = json["is_error"] as? Bool ?? false

        if let sid = json["session_id"] as? String {
            cliSessionId = sid
        }

        // Don't emit .done here — the provider emits .done on process termination
        // so it can include the final usage summary
        return nil
    }
}
