import Foundation

/// Mirrors MCP server definitions into the local Codex CLI config via `codex mcp`.
/// Uses the CLI itself instead of editing ~/.codex/config.toml directly.
@MainActor
@Observable
final class CodexMCPConfigManager {
    static let shared = CodexMCPConfigManager()

    static let worldTreeServerName = "world-tree"
    static let cortanaServerName = "cortana-core"
    static let configPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.codex/config.toml"
    }()

    static var worldTreeMCPURL: String {
        "http://127.0.0.1:\(PluginServer.port)/mcp"
    }

    static let cortanaMCPURL = "http://127.0.0.1:8765/mcp"

    var servers: [CodexMCPServerConfig] = []
    var lastError: String?
    var isSyncing = false
    var lastSyncAt: Date?

    var isInstalled: Bool {
        executablePath != nil
    }

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let runQueue = DispatchQueue(label: "com.cortana.canvas.codex-mcp", qos: .userInitiated)

    private let executablePath: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }()

    private init() {
        reload()
    }

    // MARK: - Read

    func reload() {
        Task {
            await reloadAsync()
        }
    }

    func reloadAsync() async {
        guard let executablePath else {
            servers = []
            lastError = "Codex CLI not found"
            return
        }

        do {
            servers = try await fetchServers(executablePath: executablePath)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Sync

    func syncFromClaude(includeWorldTree: Bool) {
        Task {
            await syncFromClaudeAsync(includeWorldTree: includeWorldTree)
        }
    }

    func syncFromClaudeAsync(includeWorldTree: Bool) async {
        guard let executablePath else {
            servers = []
            lastError = "Codex CLI not found"
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        MCPConfigManager.shared.reload()

        do {
            let desiredServers = Self.desiredServers(
                from: MCPConfigManager.shared.servers,
                includeWorldTree: includeWorldTree
            )
            let existingServers = try await fetchServers(executablePath: executablePath)
            var existingByName = Dictionary(uniqueKeysWithValues: existingServers.map { ($0.name, $0) })

            for desired in desiredServers {
                if let existing = existingByName[desired.name], existing.matches(desired) {
                    continue
                }

                if existingByName[desired.name] != nil {
                    try await runCodex(
                        executablePath: executablePath,
                        arguments: ["mcp", "remove", desired.name]
                    )
                }

                try await add(desired, executablePath: executablePath)
                existingByName[desired.name] = nil
            }

            if !includeWorldTree, existingByName[Self.worldTreeServerName] != nil {
                try await runCodex(
                    executablePath: executablePath,
                    arguments: ["mcp", "remove", Self.worldTreeServerName]
                )
            }

            servers = try await fetchServers(executablePath: executablePath)
            lastSyncAt = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            await reloadAsync()
        }
    }

    func removeWorldTreeRegistration() async {
        guard let executablePath else {
            lastError = "Codex CLI not found"
            return
        }

        do {
            let existingServers = try await fetchServers(executablePath: executablePath)
            guard existingServers.contains(where: { $0.name == Self.worldTreeServerName }) else {
                servers = existingServers
                lastError = nil
                return
            }

            isSyncing = true
            defer { isSyncing = false }

            try await runCodex(
                executablePath: executablePath,
                arguments: ["mcp", "remove", Self.worldTreeServerName]
            )
            servers = try await fetchServers(executablePath: executablePath)
            lastSyncAt = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            await reloadAsync()
        }
    }

    // MARK: - Helpers

    var worldTreeServer: CodexMCPServerConfig? {
        servers.first(where: { $0.name == Self.worldTreeServerName })
    }

    var worldTreeRegistered: Bool {
        worldTreeServer?.matches(Self.worldTreeDesiredServer) == true
    }

    var sharedServerNamesWithClaude: [String] {
        let claudeNames = Set(MCPConfigManager.shared.servers.map(\.name))
        let codexNames = Set(servers.map(\.name))
        return claudeNames.intersection(codexNames).sorted()
    }

    var missingServerNamesFromCodex: [String] {
        let claudeNames = Set(MCPConfigManager.shared.servers.map(\.name))
        let codexNames = Set(servers.map(\.name))
        return claudeNames.subtracting(codexNames).sorted()
    }

    // MARK: - Static helpers used in tests

    static var worldTreeDesiredServer: CodexMCPDesiredServer {
        CodexMCPDesiredServer(
            name: worldTreeServerName,
            transport: .http(url: worldTreeMCPURL)
        )
    }

    static func desiredServers(
        from claudeServers: [MCPServerConfig],
        includeWorldTree: Bool
    ) -> [CodexMCPDesiredServer] {
        var desiredByName: [String: CodexMCPDesiredServer] = [:]

        for server in claudeServers where !server.name.isEmpty {
            if let url = server.url, !url.isEmpty {
                desiredByName[server.name] = CodexMCPDesiredServer(
                    name: server.name,
                    transport: .http(url: url)
                )
            } else if !server.command.isEmpty {
                desiredByName[server.name] = CodexMCPDesiredServer(
                    name: server.name,
                    transport: .stdio(
                        command: server.command,
                        args: server.args,
                        env: server.env,
                        cwd: nil
                    )
                )
            }
        }

        if includeWorldTree {
            desiredByName[worldTreeServerName] = worldTreeDesiredServer
        }

        desiredByName[cortanaServerName] = cortanaDesiredServer

        return desiredByName.values.sorted { $0.name < $1.name }
    }

    static var cortanaDesiredServer: CodexMCPDesiredServer {
        CodexMCPDesiredServer(
            name: cortanaServerName,
            transport: .http(url: cortanaMCPURL)
        )
    }

    static func parseServerNames(from output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.hasPrefix("WARNING:"),
                      !trimmed.hasPrefix("Name ")
                else {
                    return nil
                }

                return trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init)
            }
    }

    // MARK: - Private

    private func fetchServers(executablePath: String) async throws -> [CodexMCPServerConfig] {
        let listOutput = try await runCodex(executablePath: executablePath, arguments: ["mcp", "list"])
        let names = Self.parseServerNames(from: listOutput)

        var parsed: [CodexMCPServerConfig] = []
        let decoder = JSONDecoder()

        for name in names {
            let json = try await runCodex(
                executablePath: executablePath,
                arguments: ["mcp", "get", name, "--json"]
            )
            let data = Data(json.utf8)
            parsed.append(try decoder.decode(CodexMCPServerConfig.self, from: data))
        }

        return parsed.sorted { $0.name < $1.name }
    }

    private func add(_ desired: CodexMCPDesiredServer, executablePath: String) async throws {
        switch desired.transport {
        case .http(let url):
            try await runCodex(
                executablePath: executablePath,
                arguments: ["mcp", "add", desired.name, "--url", url]
            )

        case .stdio(let command, let args, let env, _):
            var commandArgs = ["mcp", "add", desired.name]
            for key in env.keys.sorted() {
                commandArgs += ["--env", "\(key)=\(env[key] ?? "")"]
            }
            commandArgs.append("--")
            commandArgs.append(command)
            commandArgs += args
            try await runCodex(executablePath: executablePath, arguments: commandArgs)
        }
    }

    private func runCodex(executablePath: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            runQueue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments

                var env = ProcessInfo.processInfo.environment
                let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                env["PATH"] = "\(self.home)/.local/bin:\(self.home)/.cortana/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
                env["HOME"] = self.home
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdoutText = String(data: stdoutData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let stderrText = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    guard process.terminationStatus == 0 else {
                        let message = stderrText.isEmpty ? stdoutText : stderrText
                        continuation.resume(throwing: CodexMCPConfigError.commandFailed(
                            arguments.joined(separator: " "),
                            message.isEmpty ? "Codex exited with status \(process.terminationStatus)" : message
                        ))
                        return
                    }

                    continuation.resume(returning: stdoutText)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct CodexMCPServerConfig: Identifiable, Hashable, Decodable {
    let name: String
    let enabled: Bool
    let disabledReason: String?
    let transport: CodexMCPTransport
    let enabledTools: [String]?
    let disabledTools: [String]?
    let startupTimeoutSec: Int?
    let toolTimeoutSec: Int?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case enabled
        case disabledReason = "disabled_reason"
        case transport
        case enabledTools = "enabled_tools"
        case disabledTools = "disabled_tools"
        case startupTimeoutSec = "startup_timeout_sec"
        case toolTimeoutSec = "tool_timeout_sec"
    }

    func matches(_ desired: CodexMCPDesiredServer) -> Bool {
        guard name == desired.name, enabled else { return false }

        switch (transport, desired.transport) {
        case let (.stdio(command, args, env, cwd), .stdio(desiredCommand, desiredArgs, desiredEnv, desiredCwd)):
            return command == desiredCommand
                && args == desiredArgs
                && env == desiredEnv
                && cwd == desiredCwd

        case let (.http(url), .http(desiredURL)):
            return url == desiredURL

        default:
            return false
        }
    }
}

enum CodexMCPTransport: Hashable, Decodable {
    case stdio(command: String, args: [String], env: [String: String], cwd: String?)
    case http(url: String)
    case unknown(type: String)

    enum CodingKeys: String, CodingKey {
        case type
        case command
        case args
        case env
        case cwd
        case url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "stdio":
            self = .stdio(
                command: try container.decode(String.self, forKey: .command),
                args: try container.decodeIfPresent([String].self, forKey: .args) ?? [],
                env: try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:],
                cwd: try container.decodeIfPresent(String.self, forKey: .cwd)
            )

        case "http", "streamable_http", "sse":
            self = .http(url: try container.decode(String.self, forKey: .url))

        default:
            self = .unknown(type: type)
        }
    }

    var displayValue: String {
        switch self {
        case .stdio(let command, let args, _, _):
            return ([command] + args).joined(separator: " ")
        case .http(let url):
            return url
        case .unknown(let type):
            return type
        }
    }
}

struct CodexMCPDesiredServer: Hashable {
    let name: String
    let transport: CodexMCPDesiredTransport
}

enum CodexMCPDesiredTransport: Hashable {
    case stdio(command: String, args: [String], env: [String: String], cwd: String?)
    case http(url: String)
}

enum CodexMCPConfigError: LocalizedError {
    case commandFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let message):
            return "\(command): \(message)"
        }
    }
}
