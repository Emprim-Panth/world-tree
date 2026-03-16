import AppKit
import Foundation

/// Reads and writes MCP server configuration from ~/.claude/settings.json.
/// Provides structured access to server definitions, tool lists, and permission state.
@MainActor
@Observable
final class MCPConfigManager {
    static let shared = MCPConfigManager()

    var servers: [MCPServerConfig] = []
    var permissions: [String] = []
    var lastError: String?

    private let settingsPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/settings.json"
    }()

    private init() {
        reload()
    }

    // MARK: - Read

    func reload() {
        guard FileManager.default.fileExists(atPath: settingsPath),
              let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastError = "Could not read \(settingsPath)"
            return
        }

        // Parse MCP servers
        var parsed: [MCPServerConfig] = []
        if let mcpServers = json["mcpServers"] as? [String: Any] {
            for (name, value) in mcpServers {
                // Skip retired/string entries
                guard let config = value as? [String: Any] else { continue }

                let command = config["command"] as? String ?? ""
                let args = config["args"] as? [String] ?? []
                let env = config["env"] as? [String: String] ?? [:]
                let url = config["url"] as? String
                let transportType = config["type"] as? String

                // Resolve source file path from args
                let sourcePath = args.first(where: { $0.hasSuffix(".ts") || $0.hasSuffix(".js") || $0.hasSuffix(".py") })

                parsed.append(MCPServerConfig(
                    name: name,
                    command: command,
                    args: args,
                    env: env,
                    sourcePath: sourcePath,
                    url: url,
                    transportType: transportType
                ))
            }
        }
        servers = parsed.sorted { $0.name < $1.name }

        // Parse permissions
        if let perms = json["permissions"] as? [String: Any],
           let allow = perms["allow"] as? [String] {
            permissions = allow.filter { $0.hasPrefix("mcp__") }
        }

        lastError = nil
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
