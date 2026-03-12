import XCTest
@testable import WorldTree

// MARK: - ConversationStateManager Tests

/// Tests for ConversationStateManager — API message serialization, system prompt management,
/// token usage accumulation, message sanitization, and forking logic.
/// These tests exercise the in-memory state management without requiring a live database
/// or network calls.
@MainActor
final class ConversationStateManagerTests: XCTestCase {

    private func makeManager(
        sessionId: String = "test-session",
        branchId: String = "test-branch"
    ) -> ConversationStateManager {
        ConversationStateManager(sessionId: sessionId, branchId: branchId)
    }

    // MARK: - 1. Message Addition

    func testAddUserMessage() {
        let mgr = makeManager()

        mgr.addUserMessage("Hello, Cortana")

        XCTAssertEqual(mgr.apiMessages.count, 1)
        XCTAssertEqual(mgr.apiMessages[0].role, "user")
        XCTAssertEqual(mgr.apiMessages[0].content.count, 1)

        if case .text(let text) = mgr.apiMessages[0].content[0] {
            XCTAssertEqual(text, "Hello, Cortana")
        } else {
            XCTFail("Expected text content block")
        }
    }

    func testAddAssistantResponse() {
        let mgr = makeManager()

        let blocks: [ContentBlock] = [
            .text("Here's my answer"),
            .text("And a follow-up")
        ]
        mgr.addAssistantResponse(blocks)

        XCTAssertEqual(mgr.apiMessages.count, 1)
        XCTAssertEqual(mgr.apiMessages[0].role, "assistant")
        XCTAssertEqual(mgr.apiMessages[0].content.count, 2)
    }

    func testAddToolResults() {
        let mgr = makeManager()

        mgr.addToolResults([
            (toolUseId: "tool-1", content: "File contents here", isError: false),
            (toolUseId: "tool-2", content: "Command failed", isError: true),
        ])

        XCTAssertEqual(mgr.apiMessages.count, 1)
        XCTAssertEqual(mgr.apiMessages[0].role, "user")
        XCTAssertEqual(mgr.apiMessages[0].content.count, 2)

        // Verify tool result blocks
        if case .toolResult(let result) = mgr.apiMessages[0].content[0] {
            XCTAssertEqual(result.toolUseId, "tool-1")
            XCTAssertFalse(result.isError)
        } else {
            XCTFail("Expected tool_result content block")
        }

        if case .toolResult(let result) = mgr.apiMessages[0].content[1] {
            XCTAssertEqual(result.toolUseId, "tool-2")
            XCTAssertTrue(result.isError)
        } else {
            XCTFail("Expected tool_result content block")
        }
    }

    // MARK: - 2. Tool Result Truncation

    func testOversizedToolResultTruncation() {
        let mgr = makeManager()
        let bigContent = String(repeating: "x", count: 60_000)

        mgr.addToolResults([
            (toolUseId: "big-tool", content: bigContent, isError: false)
        ])

        if case .toolResult(let result) = mgr.apiMessages[0].content[0] {
            XCTAssertLessThan(result.content.count, bigContent.count,
                              "Oversized tool result should be truncated inline")
            XCTAssertTrue(result.content.contains("Truncated"),
                          "Truncated content should include truncation marker")
        } else {
            XCTFail("Expected tool_result content block")
        }
    }

    // MARK: - 3. API Message Serialization Round-Trip

    func testAPIMessageEncodingDecoding() throws {
        let original = APIMessage(role: "user", content: [
            .text("What is this code doing?")
        ])

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(APIMessage.self, from: data)

        XCTAssertEqual(decoded.role, "user")
        XCTAssertEqual(decoded.content.count, 1)

        if case .text(let text) = decoded.content[0] {
            XCTAssertEqual(text, "What is this code doing?")
        } else {
            XCTFail("Round-trip should preserve text content block")
        }
    }

    func testToolResultEncodingDecoding() throws {
        let original = APIMessage(role: "user", content: [
            .toolResult(ContentBlock.ToolResultBlock(
                toolUseId: "toolu_123",
                content: "Success output",
                isError: false
            ))
        ])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(APIMessage.self, from: data)

        if case .toolResult(let result) = decoded.content[0] {
            XCTAssertEqual(result.toolUseId, "toolu_123")
            XCTAssertEqual(result.content, "Success output")
            XCTAssertFalse(result.isError)
        } else {
            XCTFail("Round-trip should preserve tool_result block")
        }
    }

    // MARK: - 4. System Prompt Management

    func testAppendKBContextReplacesExisting() {
        let mgr = makeManager()

        // Simulate initial system blocks
        mgr.appendKBContext("First knowledge context")
        let countAfterFirst = mgr.systemBlocks.count

        // Append again — should replace, not accumulate
        mgr.appendKBContext("Second knowledge context")
        let countAfterSecond = mgr.systemBlocks.count

        XCTAssertEqual(countAfterFirst, countAfterSecond,
                       "appendKBContext should replace previous KB block, not accumulate")

        let kbBlocks = mgr.systemBlocks.filter { $0.text.hasPrefix("[Relevant knowledge]") }
        XCTAssertEqual(kbBlocks.count, 1, "Should have exactly one KB block")
        XCTAssertTrue(kbBlocks[0].text.contains("Second knowledge context"),
                      "KB block should contain the latest context")
    }

    func testAppendEmptyKBContextRemovesExisting() {
        let mgr = makeManager()

        mgr.appendKBContext("Some knowledge")
        XCTAssertEqual(mgr.systemBlocks.filter { $0.text.hasPrefix("[Relevant knowledge]") }.count, 1)

        mgr.appendKBContext("")
        XCTAssertEqual(mgr.systemBlocks.filter { $0.text.hasPrefix("[Relevant knowledge]") }.count, 0,
                       "Empty KB context should remove existing KB blocks")
    }

    // MARK: - 5. Token Usage Accumulation

    func testTokenUsageAccumulation() {
        let mgr = makeManager()

        XCTAssertEqual(mgr.tokenUsage.totalInputTokens, 0)
        XCTAssertEqual(mgr.tokenUsage.totalOutputTokens, 0)
        XCTAssertEqual(mgr.tokenUsage.turnCount, 0)

        mgr.recordUsage(TokenUsage(inputTokens: 1000, outputTokens: 500))
        XCTAssertEqual(mgr.tokenUsage.totalInputTokens, 1000)
        XCTAssertEqual(mgr.tokenUsage.totalOutputTokens, 500)
        XCTAssertEqual(mgr.tokenUsage.turnCount, 1)

        mgr.recordUsage(TokenUsage(inputTokens: 2000, outputTokens: 800,
                                    cacheCreationInputTokens: 100,
                                    cacheReadInputTokens: 50))
        XCTAssertEqual(mgr.tokenUsage.totalInputTokens, 3000)
        XCTAssertEqual(mgr.tokenUsage.totalOutputTokens, 1300)
        XCTAssertEqual(mgr.tokenUsage.cacheCreationTokens, 100)
        XCTAssertEqual(mgr.tokenUsage.cacheHitTokens, 50)
        XCTAssertEqual(mgr.tokenUsage.turnCount, 2)
    }

    // MARK: - 6. Message Sanitization via messagesForAPI

    func testMessagesForAPIEnsuresUserFirst() {
        let mgr = makeManager()

        // Add an assistant message first (violates API requirement)
        mgr.addAssistantResponse([.text("I shouldn't be first")])
        mgr.addUserMessage("Now I'm the user")
        mgr.addAssistantResponse([.text("Response")])

        let messages = mgr.messagesForAPI()

        XCTAssertEqual(messages.first?.role, "user",
                       "messagesForAPI must ensure the first message is from user")
    }

    func testMessagesForAPIMergesConsecutiveSameRole() {
        let mgr = makeManager()

        // Add two consecutive user messages (violates strict alternation)
        mgr.addUserMessage("Part one")
        mgr.addUserMessage("Part two")
        mgr.addAssistantResponse([.text("Response")])

        let messages = mgr.messagesForAPI()

        // The two user messages should be merged into one
        let userMessages = messages.filter { $0.role == "user" }
        XCTAssertEqual(userMessages.count, 1,
                       "Consecutive same-role messages should be merged")
        XCTAssertEqual(userMessages[0].content.count, 2,
                       "Merged message should contain both content blocks")
    }

    // MARK: - 7. Forking

    func testForkInheritsParentState() {
        let parent = makeManager(sessionId: "parent-session", branchId: "parent-branch")

        // Build up parent state
        parent.addUserMessage("Question 1")
        parent.addAssistantResponse([.text("Answer 1")])
        parent.addUserMessage("Question 2")
        parent.addAssistantResponse([.text("Answer 2")])

        // Fork after the first exchange (index 2 = first 2 messages)
        let child = ConversationStateManager.fork(
            from: parent,
            upToMessageIndex: 2,
            newSessionId: "child-session",
            newBranchId: "child-branch"
        )

        XCTAssertEqual(child.sessionId, "child-session")
        XCTAssertEqual(child.branchId, "child-branch")
        XCTAssertEqual(child.apiMessages.count, 2,
                       "Child should inherit first 2 messages from parent")
        XCTAssertEqual(child.apiMessages[0].role, "user")
        XCTAssertEqual(child.apiMessages[1].role, "assistant")
    }

    func testForkWithZeroIndexCreatesEmpty() {
        let parent = makeManager()
        parent.addUserMessage("Hello")

        let child = ConversationStateManager.fork(
            from: parent,
            upToMessageIndex: 0,
            newSessionId: "new-sess",
            newBranchId: "new-branch"
        )

        XCTAssertTrue(child.apiMessages.isEmpty,
                      "Fork with index 0 should create empty message history")
    }

    // MARK: - 8. SessionTokenUsage Codable

    func testSessionTokenUsageCodableRoundTrip() throws {
        var usage = SessionTokenUsage()
        usage.totalInputTokens = 5000
        usage.totalOutputTokens = 2500
        usage.cacheHitTokens = 300
        usage.cacheCreationTokens = 150
        usage.turnCount = 7

        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(SessionTokenUsage.self, from: data)

        XCTAssertEqual(decoded.totalInputTokens, 5000)
        XCTAssertEqual(decoded.totalOutputTokens, 2500)
        XCTAssertEqual(decoded.cacheHitTokens, 300)
        XCTAssertEqual(decoded.cacheCreationTokens, 150)
        XCTAssertEqual(decoded.turnCount, 7)
    }
}
