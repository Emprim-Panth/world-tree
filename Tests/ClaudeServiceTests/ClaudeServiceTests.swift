import XCTest
@testable import WorldTree

// MARK: - ClaudeService Tests

/// Tests for ClaudeService and supporting types — error types, model construction,
/// Anthropic API types (AnthropicRequest, ContentBlock, TokenUsage, etc.), and
/// streaming SSE payload decoding.
@MainActor
final class ClaudeServiceTests: XCTestCase {

    // MARK: - 1. ClaudeServiceError

    func testClaudeServiceErrorDescriptions() {
        let noKey = ClaudeServiceError.noAPIKey
        XCTAssertNotNil(noKey.errorDescription)
        XCTAssertTrue(noKey.errorDescription!.contains("API key"),
                      "noAPIKey error should mention API key")

        let apiErr = ClaudeServiceError.apiError("Rate limit exceeded")
        XCTAssertTrue(apiErr.errorDescription!.contains("Rate limit exceeded"),
                      "apiError should include the message")
    }

    // MARK: - 2. AnthropicClientError Classification

    func testAnthropicClientErrorDescriptions() {
        XCTAssertNotNil(AnthropicClientError.noAPIKey.errorDescription)
        XCTAssertNotNil(AnthropicClientError.invalidResponse.errorDescription)
        XCTAssertNotNil(AnthropicClientError.overloaded.errorDescription)

        let httpErr = AnthropicClientError.httpError(status: 500, body: "Internal Server Error")
        XCTAssertTrue(httpErr.errorDescription!.contains("500"))

        let rateLimited = AnthropicClientError.rateLimited(retryAfter: 30)
        XCTAssertTrue(rateLimited.errorDescription!.contains("30"))

        let rateLimitedNoAfter = AnthropicClientError.rateLimited(retryAfter: nil)
        XCTAssertNotNil(rateLimitedNoAfter.errorDescription)

        let streamErr = AnthropicClientError.streamingError("connection reset")
        XCTAssertTrue(streamErr.errorDescription!.contains("connection reset"))
    }

    // MARK: - 3. TokenUsage

    func testTokenUsageZero() {
        let zero = TokenUsage.zero
        XCTAssertEqual(zero.inputTokens, 0)
        XCTAssertEqual(zero.outputTokens, 0)
        XCTAssertNil(zero.cacheCreationInputTokens)
        XCTAssertNil(zero.cacheReadInputTokens)
    }

    func testTokenUsageAdd() {
        var base = TokenUsage(inputTokens: 100, outputTokens: 50)
        let addition = TokenUsage(
            inputTokens: 200,
            outputTokens: 100,
            cacheCreationInputTokens: 30,
            cacheReadInputTokens: 20
        )
        base.add(addition)

        XCTAssertEqual(base.inputTokens, 300)
        XCTAssertEqual(base.outputTokens, 150)
        XCTAssertEqual(base.cacheCreationInputTokens, 30)
        XCTAssertEqual(base.cacheReadInputTokens, 20)
    }

    func testTokenUsageAddAccumulates() {
        var base = TokenUsage(
            inputTokens: 100,
            outputTokens: 50,
            cacheCreationInputTokens: 10,
            cacheReadInputTokens: 5
        )
        let addition = TokenUsage(
            inputTokens: 200,
            outputTokens: 100,
            cacheCreationInputTokens: 20,
            cacheReadInputTokens: 15
        )
        base.add(addition)

        XCTAssertEqual(base.cacheCreationInputTokens, 30, "Cache creation should accumulate")
        XCTAssertEqual(base.cacheReadInputTokens, 20, "Cache read should accumulate")
    }

    func testTokenUsageCodableRoundTrip() throws {
        let original = TokenUsage(
            inputTokens: 5000,
            outputTokens: 2500,
            cacheCreationInputTokens: 100,
            cacheReadInputTokens: 200
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)

        XCTAssertEqual(decoded.inputTokens, 5000)
        XCTAssertEqual(decoded.outputTokens, 2500)
        XCTAssertEqual(decoded.cacheCreationInputTokens, 100)
        XCTAssertEqual(decoded.cacheReadInputTokens, 200)
    }

    // MARK: - 4. ContentBlock Encoding/Decoding

    func testTextBlockRoundTrip() throws {
        let original = ContentBlock.text("Hello from tests")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)

        if case .text(let text) = decoded {
            XCTAssertEqual(text, "Hello from tests")
        } else {
            XCTFail("Expected text block after round-trip")
        }
    }

    func testToolResultBlockRoundTrip() throws {
        let original = ContentBlock.toolResult(ContentBlock.ToolResultBlock(
            toolUseId: "toolu_abc123",
            content: "Command output here",
            isError: false
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)

        if case .toolResult(let result) = decoded {
            XCTAssertEqual(result.toolUseId, "toolu_abc123")
            XCTAssertEqual(result.content, "Command output here")
            XCTAssertFalse(result.isError)
        } else {
            XCTFail("Expected tool_result block after round-trip")
        }
    }

    func testToolResultErrorBlockRoundTrip() throws {
        let original = ContentBlock.toolResult(ContentBlock.ToolResultBlock(
            toolUseId: "toolu_err",
            content: "Permission denied",
            isError: true
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)

        if case .toolResult(let result) = decoded {
            XCTAssertTrue(result.isError)
        } else {
            XCTFail("Expected tool_result block after round-trip")
        }
    }

    func testImageBlockRoundTrip() throws {
        let original = ContentBlock.image(ContentBlock.ImageBlock(
            mediaType: "image/png",
            data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)

        if case .image(let img) = decoded {
            XCTAssertEqual(img.mediaType, "image/png")
            XCTAssertFalse(img.data.isEmpty)
        } else {
            XCTFail("Expected image block after round-trip")
        }
    }

    // MARK: - 5. ThinkingConfig

    func testAdaptiveThinkingConfig() throws {
        let config = ThinkingConfig.adaptive()
        XCTAssertEqual(config.type, "adaptive")
        XCTAssertNil(config.budgetTokens)

        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "adaptive")
        XCTAssertNil(json?["budget_tokens"],
                     "Adaptive thinking should not include budget_tokens in JSON")
    }

    func testEnabledThinkingConfig() throws {
        let config = ThinkingConfig.enabled(budgetTokens: 10000)
        XCTAssertEqual(config.type, "enabled")
        XCTAssertEqual(config.budgetTokens, 10000)

        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["budget_tokens"] as? Int, 10000)
    }

    // MARK: - 6. RateLimitInfo

    func testRateLimitInfoNearLimit() {
        let nearRequests = RateLimitInfo(
            requestsRemaining: 5,
            tokensRemaining: 100_000,
            requestsReset: nil,
            tokensReset: nil
        )
        XCTAssertTrue(nearRequests.isNearLimit, "Should be near limit when requests < 10")

        let nearTokens = RateLimitInfo(
            requestsRemaining: 100,
            tokensRemaining: 30_000,
            requestsReset: nil,
            tokensReset: nil
        )
        XCTAssertTrue(nearTokens.isNearLimit, "Should be near limit when tokens < 50_000")

        let comfortable = RateLimitInfo(
            requestsRemaining: 100,
            tokensRemaining: 100_000,
            requestsReset: nil,
            tokensReset: nil
        )
        XCTAssertFalse(comfortable.isNearLimit, "Should not be near limit with comfortable headroom")
    }

    func testRateLimitInfoWithNils() {
        let unknown = RateLimitInfo(
            requestsRemaining: nil,
            tokensRemaining: nil,
            requestsReset: nil,
            tokensReset: nil
        )
        XCTAssertFalse(unknown.isNearLimit,
                       "Should not report near limit when values are unknown")
    }

    // MARK: - 7. APIError

    func testAPIErrorMessageExtraction() {
        let withDetail = APIError(
            type: "error",
            error: APIError.ErrorDetail(type: "invalid_request", message: "Missing model field"),
            message: nil
        )
        XCTAssertEqual(withDetail.errorMessage, "Missing model field")

        let withMessage = APIError(type: "error", error: nil, message: "Fallback message")
        XCTAssertEqual(withMessage.errorMessage, "Fallback message")

        let withBoth = APIError(
            type: "error",
            error: APIError.ErrorDetail(type: "bad_request", message: "Detail wins"),
            message: "Ignored fallback"
        )
        XCTAssertEqual(withBoth.errorMessage, "Detail wins",
                       "error.message should take priority over top-level message")

        let withNeither = APIError(type: "error", error: nil, message: nil)
        XCTAssertEqual(withNeither.errorMessage, "Unknown API error")
    }

    // MARK: - 8. DeltaContent Decoding

    func testTextDeltaDecoding() throws {
        let json = #"{"type": "text_delta", "text": "Hello"}"#
        let delta = try JSONDecoder().decode(DeltaContent.self, from: json.data(using: .utf8)!)

        if case .textDelta(let text) = delta {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected textDelta")
        }
    }

    func testInputJsonDeltaDecoding() throws {
        let json = #"{"type": "input_json_delta", "partial_json": "{\"command\":"}"#
        let delta = try JSONDecoder().decode(DeltaContent.self, from: json.data(using: .utf8)!)

        if case .inputJsonDelta(let partial) = delta {
            XCTAssertTrue(partial.contains("command"))
        } else {
            XCTFail("Expected inputJsonDelta")
        }
    }

    func testThinkingDeltaDecoding() throws {
        let json = #"{"type": "thinking_delta", "thinking": "Let me consider..."}"#
        let delta = try JSONDecoder().decode(DeltaContent.self, from: json.data(using: .utf8)!)

        if case .thinkingDelta(let thinking) = delta {
            XCTAssertEqual(thinking, "Let me consider...")
        } else {
            XCTFail("Expected thinkingDelta")
        }
    }

    func testUnknownDeltaTypeFallsBackToEmptyText() throws {
        let json = #"{"type": "unknown_new_type"}"#
        let delta = try JSONDecoder().decode(DeltaContent.self, from: json.data(using: .utf8)!)

        if case .textDelta(let text) = delta {
            XCTAssertEqual(text, "", "Unknown delta type should fall back to empty textDelta")
        } else {
            XCTFail("Expected textDelta fallback for unknown type")
        }
    }

    // MARK: - 9. AnthropicRequest Encoding

    func testAnthropicRequestOmitsThinkingWhenNil() throws {
        let request = AnthropicRequest(
            model: "claude-sonnet-4-20250514",
            maxTokens: 4096,
            system: [SystemBlock(text: "You are helpful")],
            tools: [],
            messages: [APIMessage(role: "user", content: [.text("Hi")])],
            stream: true,
            thinking: nil
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["model"])
        XCTAssertNil(json?["thinking"],
                     "Nil thinking config should be omitted from JSON")
    }

    func testAnthropicRequestIncludesThinkingWhenSet() throws {
        var request = AnthropicRequest(
            model: "claude-opus-4-20250514",
            maxTokens: 16384,
            system: [],
            tools: [],
            messages: [APIMessage(role: "user", content: [.text("Think deeply")])],
            stream: true,
            thinking: .adaptive()
        )
        request.effort = .high

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["thinking"], "Thinking config should be present when set")
        XCTAssertNotNil(json?["output_config"], "Effort should be encoded as output_config")

        if let thinking = json?["thinking"] as? [String: Any] {
            XCTAssertEqual(thinking["type"] as? String, "adaptive")
        }
    }

    // MARK: - 10. ProviderCapabilities

    func testProviderCapabilitiesOptionSet() {
        let caps: ProviderCapabilities = [.streaming, .toolExecution, .promptCaching]

        XCTAssertTrue(caps.contains(.streaming))
        XCTAssertTrue(caps.contains(.toolExecution))
        XCTAssertTrue(caps.contains(.promptCaching))
        XCTAssertFalse(caps.contains(.sessionResume))
        XCTAssertFalse(caps.contains(.costTracking))
    }

    func testProviderHealthUsability() {
        XCTAssertTrue(ProviderHealth.available.isUsable)
        XCTAssertTrue(ProviderHealth.degraded(reason: "slow").isUsable)
        XCTAssertFalse(ProviderHealth.unavailable(reason: "no key").isUsable)
    }

    func testProviderHealthStatusLabel() {
        XCTAssertEqual(ProviderHealth.available.statusLabel, "Available")
        XCTAssertTrue(ProviderHealth.degraded(reason: "slow").statusLabel.contains("slow"))
        XCTAssertTrue(ProviderHealth.unavailable(reason: "no key").statusLabel.contains("no key"))
    }
}
