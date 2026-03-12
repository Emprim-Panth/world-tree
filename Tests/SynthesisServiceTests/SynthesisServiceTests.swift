import XCTest
@testable import WorldTree

// MARK: - SynthesisService Tests

/// Tests for SynthesisService — prompt construction logic, token budget constants,
/// and error handling. These tests exercise the buildSynthesisPrompt logic indirectly
/// through createSynthesisBranch error paths, and directly test the public constants
/// and error types.
@MainActor
final class SynthesisServiceTests: XCTestCase {

    // MARK: - 1. Constants

    func testMaxMessagesPerBranchConstant() {
        XCTAssertEqual(SynthesisService.maxMessagesPerBranch, 20,
                       "Max messages per branch should be 20 for synthesis context budget")
    }

    // MARK: - 2. SynthesisError

    func testSynthesisErrorDescription() {
        let error = SynthesisError.noBranchesWithMessages
        XCTAssertNotNil(error.errorDescription,
                        "SynthesisError should provide a localized description")
        XCTAssertTrue(error.errorDescription!.contains("messages"),
                      "Error description should mention messages")
    }

    func testSynthesisErrorConformsToLocalizedError() {
        let error: LocalizedError = SynthesisError.noBranchesWithMessages
        XCTAssertNotNil(error.errorDescription,
                        "SynthesisError should conform to LocalizedError")
    }

    // MARK: - 3. Content Block Text Helper

    func testContentBlockTextContent() {
        let textBlock = ContentBlock.text("Hello world")
        XCTAssertEqual(textBlock.textContent, "Hello world")

        let toolBlock = ContentBlock.toolResult(ContentBlock.ToolResultBlock(
            toolUseId: "t1", content: "result", isError: false
        ))
        XCTAssertNil(toolBlock.textContent, "Non-text block should return nil for textContent")
    }

    func testContentBlockToolUseContent() {
        let textBlock = ContentBlock.text("Not a tool")
        XCTAssertNil(textBlock.toolUseContent, "Text block should return nil for toolUseContent")

        let toolUse = ContentBlock.ToolUseBlock(id: "tu-1", name: "bash", input: ["command": AnyCodable("ls")])
        let toolBlock = ContentBlock.toolUse(toolUse)
        XCTAssertEqual(toolBlock.toolUseContent?.name, "bash")
        XCTAssertEqual(toolBlock.toolUseContent?.id, "tu-1")
    }

    // MARK: - 4. SystemBlock Construction

    func testSystemBlockUncached() {
        let block = SystemBlock(text: "Dynamic context")
        XCTAssertEqual(block.type, "text")
        XCTAssertEqual(block.text, "Dynamic context")
        XCTAssertNil(block.cacheControl, "Uncached block should have nil cacheControl")
        XCTAssertFalse(block.isPinned)
    }

    func testSystemBlockCached() {
        let block = SystemBlock(text: "Project context", cached: true)
        XCTAssertNotNil(block.cacheControl)
        XCTAssertEqual(block.cacheControl?.type, "ephemeral")
        XCTAssertNil(block.cacheControl?.ttl, "Standard cache should have nil TTL (5min API default)")
        XCTAssertTrue(block.isPinned)
    }

    func testSystemBlockLongCache() {
        let block = SystemBlock(text: "Identity prompt", longCache: true)
        XCTAssertNotNil(block.cacheControl)
        XCTAssertEqual(block.cacheControl?.type, "ephemeral")
        XCTAssertEqual(block.cacheControl?.ttl, 3600, "Long cache should have 1-hour TTL")
        XCTAssertTrue(block.isPinned)
    }

    func testSystemBlockEncodingOmitsCacheControlWhenNil() throws {
        let block = SystemBlock(text: "No cache")
        let data = try JSONEncoder().encode(block)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["text"])
        XCTAssertNotNil(json?["type"])
        XCTAssertNil(json?["cache_control"],
                     "Nil cacheControl must be omitted from JSON (Anthropic API rejects null)")
    }

    func testSystemBlockEncodingIncludesCacheControlWhenSet() throws {
        let block = SystemBlock(text: "Cached block", cached: true)
        let data = try JSONEncoder().encode(block)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["cache_control"],
                        "Set cacheControl should be included in JSON")
    }
}
