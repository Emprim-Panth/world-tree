import AppKit
import Foundation

/// Reads MCP server configuration from all Claude config sources:
///   - ~/.claude/settings.json  (global Claude Code settings)
///   - ~/.claude/mcp.json        (global MCP-only config — where qmd lives)
///   - ./.mcp.json               (project-level, relative to working dir)
/// Permissions are read from settings.json only.
@MainActor
@Observable
final class MCPConfigManager {
    static let shared = MCPConfigManager()

    var servers: [MCPServerConfig] = []
    var permissions: [String] = []
    var lastError: String?

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private var settingsPath: String { "\(home)/.claude/settings.json" }
    private var mcpJsonPath: String { "\(home)/.claude/mcp.json" }

    private init() {
        reload()
    }

    // MARK: - Read

    func reload() {
        var parsed: [MCPServerConfig] = []
        var loadErrors: [String] = []

        // 1. ~/.claude/settings.json — primary config + permissions
        if let json = loadJSON(at: settingsPath) {
            parsed += parseServers(from: json, sourceFile: "settings.json")

            if let perms = json["permissions"] as? [String: Any],
               let allow = perms["allow"] as? [String] {
                permissions = allow.filter { $0.hasPrefix("mcp__") }
            }
        } else {
            loadErrors.append("Could not read settings.json")
        }

        // 2. ~/.claude/mcp.json — dedicated MCP config (qmd lives here)
        if let json = loadJSON(at: mcpJsonPath) {
            let extra = parseServers(from: json, sourceFile: "mcp.json")
            // Merge: mcp.json entries don't override settings.json entries of the same name
            let existingNames = Set(parsed.map(\.name))
            parsed += extra.filter { !existingNames.contains($0.name) }
        }

        servers = parsed.sorted { $0.name < $1.name }
        lastError = loadErrors.isEmpty ? nil : loadErrors.joined(separator: "; ")
    }

    // MARK: - Helpers

    private func loadJSON(at path: String) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func parseServers(from json: [String: Any], sourceFile: String) -> [MCPServerConfig] {
        guard let mcpServers = json["mcpServers"] as? [String: Any] else { return [] }
        var result: [MCPServerConfig] = []
        for (name, value) in mcpServers {
            guard let config = value as? [String: Any] else { continue } // skip retired string entries
            let command = config["command"] as? String ?? ""
            let args = config["args"] as? [String] ?? []
            let env = config["env"] as? [String: String] ?? [:]
            let url = config["url"] as? String
            let transportType = config["type"] as? String
            let sourcePath = args.first(where: { $0.hasSuffix(".ts") || $0.hasSuffix(".js") || $0.hasSuffix(".py") })
            result.append(MCPServerConfig(
                name: name,
                command: command,
                args: args,
                env: env,
                sourcePath: sourcePath,
                url: url,
                transportType: transportType,
                sourceFile: sourceFile
            ))
        }
        return result
    }

    // MARK: - Source file operations

    func sourceContents(for server: MCPServerConfig) -> String? {
        guard let path = server.sourcePath else { return nil }
        let expanded = path.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
        return try? String(contentsOfFile: expanded, encoding: .utf8)
    }

    func saveSource(for server: MCPServerConfig, contents: String) throws {
        guard let path = server.sourcePath else {
            throw MCPError.noSourceFile(server.name)
        }
        let expanded = path.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
        try contents.write(toFile: expanded, atomically: true, encoding: .utf8)
    }

    func openInEditor(server: MCPServerConfig) {
        guard let path = server.sourcePath else { return }
        let expanded = path.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
        let url = URL(fileURLWithPath: expanded)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Permission check

    func isAutoAllowed(_ serverName: String) -> Bool {
        permissions.contains("mcp__\(serverName)__*")
    }

    // MARK: - Parse tools from source

    func parseTools(from source: String) -> [MCPToolInfo] {
        var tools: [MCPToolInfo] = []

        // Match tool definitions in the TOOLS array: { name: "...", description: "..." }
        let namePattern = /name:\s*"([^"]+)"/
        let descPattern = /description:\s*\n?\s*"([^"]+)"/

        // Split on tool boundaries — each tool starts with { and contains name:
        let blocks = source.components(separatedBy: "{\n")
        for block in blocks {
            guard let nameMatch = block.firstMatch(of: namePattern) else { continue }
            let name = String(nameMatch.1)

            var description = ""
            if let descMatch = block.firstMatch(of: descPattern) {
                description = String(descMatch.1)
            }

            tools.append(MCPToolInfo(name: name, description: description))
        }

        return tools
    }
}

// MARK: - Models

struct MCPServerConfig: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let command: String
    let args: [String]
    let env: [String: String]
    let sourcePath: String?
    let url: String?
    let transportType: String?
    /// Which config file this server was loaded from (e.g. "settings.json", "mcp.json")
    let sourceFile: String

    var displayCommand: String {
        if let url, !url.isEmpty {
            return url
        }
        return ([command] + args).joined(separator: " ")
    }

    var isLocal: Bool {
        if let url {
            return url.contains("127.0.0.1") || url.contains("localhost")
        }
        return command == "bun" || command == "node" || command == "python3"
    }

    var isNPX: Bool {
        command == "npx"
    }

    var shortPath: String {
        if let url, !url.isEmpty {
            return url
        }
        guard let path = sourcePath else { return command }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: home, with: "~")
    }
}

struct MCPToolInfo: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String
}

enum MCPError: LocalizedError {
    case noSourceFile(String)

    var errorDescription: String? {
        switch self {
        case .noSourceFile(let name):
            return "Server '\(name)' has no local source file to edit"
        }
    }
}
