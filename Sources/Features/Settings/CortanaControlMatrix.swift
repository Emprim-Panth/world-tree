import Foundation

enum CortanaControlLevel: String, Hashable {
    case full
    case partial
    case gap
    case neutral
}

struct CortanaControlBadge: Hashable {
    let label: String
    let level: CortanaControlLevel
}

struct CortanaControlRow: Identifiable, Hashable {
    let title: String
    let claudeCode: CortanaControlBadge
    let anthropicAPI: CortanaControlBadge
    let codexCLI: CortanaControlBadge
    let note: String

    var id: String { title }
}

enum CortanaPromptPreviewTarget: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case anthropicAPI = "Anthropic API"
    case codexCLI = "Codex CLI"

    var id: String { rawValue }
}

enum CortanaControlMatrix {
    static func rows(
        claudeServerCount: Int,
        codexServerCount: Int,
        codexWorldTreeRegistered: Bool,
        pluginServerRunning: Bool
    ) -> [CortanaControlRow] {
        [
            CortanaControlRow(
                title: "Identity",
                claudeCode: CortanaControlBadge(label: "CLI overlay", level: .full),
                anthropicAPI: CortanaControlBadge(label: "Full system", level: .full),
                codexCLI: CortanaControlBadge(label: "CLI overlay", level: .full),
                note: "Both CLIs inherit the same Cortana voice. The API provider gets the larger directive block."
            ),
            CortanaControlRow(
                title: "Shared Context",
                claudeCode: CortanaControlBadge(label: "Recent + memory", level: .full),
                anthropicAPI: CortanaControlBadge(label: "Recent + memory", level: .full),
                codexCLI: CortanaControlBadge(label: "Recent + memory", level: .full),
                note: "SendContextBuilder injects recent turns, memory recall, project context, cwd, and attachments."
            ),
            CortanaControlRow(
                title: "Tool Lane",
                claudeCode: CortanaControlBadge(label: "CLI tools", level: .full),
                anthropicAPI: CortanaControlBadge(label: "World Tree tools", level: .full),
                codexCLI: CortanaControlBadge(label: "Full auto", level: .full),
                note: "Execution stacks differ, but they all run through World Tree's provider routing."
            ),
            CortanaControlRow(
                title: "Session Control",
                claudeCode: CortanaControlBadge(label: "Resume + fork", level: .full),
                anthropicAPI: CortanaControlBadge(label: "Resume + fork", level: .full),
                codexCLI: CortanaControlBadge(label: "Fresh turns", level: .partial),
                note: "Codex CLI is not wired to session resume or fork yet."
            ),
            CortanaControlRow(
                title: "MCP Registry",
                claudeCode: CortanaControlBadge(label: "\(claudeServerCount) servers", level: .full),
                anthropicAPI: CortanaControlBadge(label: "App tools only", level: .neutral),
                codexCLI: CortanaControlBadge(
                    label: "\(codexServerCount) servers",
                    level: codexServerCount >= claudeServerCount ? .full : .partial
                ),
                note: "Claude reads ~/.claude/settings.json. Codex is mirrored into ~/.codex/config.toml."
            ),
            CortanaControlRow(
                title: "World Tree MCP",
                claudeCode: CortanaControlBadge(label: "Not wired", level: .gap),
                anthropicAPI: CortanaControlBadge(label: "Not needed", level: .neutral),
                codexCLI: CortanaControlBadge(
                    label: codexWorldTreeRegistered && pluginServerRunning ? "Registered" : "Missing",
                    level: codexWorldTreeRegistered && pluginServerRunning ? .full : .gap
                ),
                note: "Codex can call the local loopback MCP server once the plugin server is running and synced."
            ),
        ]
    }

    static func promptPreview(for target: CortanaPromptPreviewTarget) -> String {
        let project = "WorldTree"
        let workingDirectory = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Development/WorldTree"

        switch target {
        case .claudeCode:
            return CortanaIdentity.cliSystemPrompt(
                project: project,
                workingDirectory: workingDirectory,
                sessionId: "preview-session"
            )

        case .anthropicAPI:
            return CortanaIdentity.fullIdentity(
                project: project,
                workingDirectory: workingDirectory
            )

        case .codexCLI:
            return CortanaIdentity.cliSystemPrompt(
                project: project,
                workingDirectory: workingDirectory,
                sessionId: "preview-session"
            )
        }
    }
}
