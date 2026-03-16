import XCTest
@testable import WorldTree

@MainActor
final class CodexMCPConfigManagerTests: XCTestCase {
    func testParseServerNamesIgnoresWarningsAndHeaders() {
        let output = """
        WARNING: proceeding, even though we could not update PATH: Operation not permitted (os error 1)
        Name    Command    Args  Env  Cwd  Status  Auth
        pencil  /Applications/Pencil.app/Contents/MacOS/pencil --app desktop - - enabled Unsupported
        context7  npx  -y @upstash/context7-mcp  - - enabled Supported
        """

        XCTAssertEqual(
            CodexMCPConfigManager.parseServerNames(from: output),
            ["pencil", "context7"]
        )
    }

    func testDesiredServersMirrorClaudeAndWorldTree() {
        let claudeServers = [
            MCPServerConfig(
                name: "context7",
                command: "npx",
                args: ["-y", "@upstash/context7-mcp"],
                env: ["CONTEXT7_API_KEY": "test-key"],
                sourcePath: nil,
                url: nil,
                transportType: nil
            )
        ]

        let desired = CodexMCPConfigManager.desiredServers(
            from: claudeServers,
            includeWorldTree: true
        )

        XCTAssertEqual(desired.map { $0.name }, ["context7", "world-tree"])

        guard case let .stdio(command, args, env, _) = desired[0].transport else {
            return XCTFail("Expected stdio transport for mirrored Claude MCP server")
        }
        XCTAssertEqual(command, "npx")
        XCTAssertEqual(args, ["-y", "@upstash/context7-mcp"])
        XCTAssertEqual(env["CONTEXT7_API_KEY"], "test-key")

        guard case let .http(url) = desired[1].transport else {
            return XCTFail("Expected http transport for World Tree MCP server")
        }
        XCTAssertEqual(url, CodexMCPConfigManager.worldTreeMCPURL)
    }

    func testWorldTreeRegistrationMatchRecognizesEquivalentHTTPServer() {
        let existing = CodexMCPServerConfig(
            name: CodexMCPConfigManager.worldTreeServerName,
            enabled: true,
            disabledReason: nil,
            transport: .http(url: CodexMCPConfigManager.worldTreeMCPURL),
            enabledTools: nil,
            disabledTools: nil,
            startupTimeoutSec: nil,
            toolTimeoutSec: nil
        )

        XCTAssertTrue(existing.matches(CodexMCPConfigManager.worldTreeDesiredServer))
    }

    func testControlMatrixHighlightsCodexSessionGap() throws {
        let rows = CortanaControlMatrix.rows(
            claudeServerCount: 5,
            codexServerCount: 5,
            codexWorldTreeRegistered: true,
            pluginServerRunning: true
        )

        let sessionRow = try XCTUnwrap(rows.first(where: { $0.title == "Session Control" }))
        XCTAssertEqual(sessionRow.codexCLI.label, "Fresh turns")
        XCTAssertEqual(sessionRow.codexCLI.level, .partial)
        XCTAssertEqual(sessionRow.claudeCode.label, "Resume + fork")
    }
}
