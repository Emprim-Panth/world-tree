import Foundation
import SwiftUI

// MARK: - Starfleet Roster

/// Loads and manages the Starfleet crew roster from ~/.cortana/starfleet/config.yaml.
/// Provides compilation and dispatch capabilities for individual agents.
@MainActor
final class StarfleetRoster: ObservableObject {
    static let shared = StarfleetRoster()

    @Published var agents: [StarfleetAgent] = []
    @Published var isLoading = false

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let compilePath: String

    init() {
        compilePath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cortana/bin/cortana-compile"
        Task { await loadRosterAsync() }
    }

    // MARK: - Load Roster

    /// Synchronous entry point for manual refresh (calls async internally).
    func loadRoster() {
        Task { await loadRosterAsync() }
    }

    /// Parse crew from cortana-compile --list and enrich with config.yaml metadata.
    private func loadRosterAsync() async {
        isLoading = true
        defer { isLoading = false }

        let configPath = "\(home)/.cortana/starfleet/config.yaml"
        let configContent = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""

        // Parse agent list from cortana-compile --list
        var parsed: [StarfleetAgent] = []
        let listOutput = await runAsync([compilePath, "--list"])

        var currentTier: StarfleetAgent.Tier = .core
        for line in listOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Core Crew:") {
                currentTier = .core
                continue
            } else if trimmed.hasPrefix("Reserves:") {
                currentTier = .reserve
                continue
            }

            // Lines like "  ✓ spock" or "  ✗ composer"
            let available = trimmed.hasPrefix("✓")
            let unavailable = trimmed.hasPrefix("✗")
            guard available || unavailable else { continue }

            let name = trimmed
                .replacingOccurrences(of: "✓", with: "")
                .replacingOccurrences(of: "✗", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !name.isEmpty else { continue }

            // Extract metadata from config.yaml using simple line scanning
            let (displayName, domain, model, triggers) = parseAgentConfig(name: name, from: configContent)

            parsed.append(StarfleetAgent(
                id: name,
                displayName: displayName ?? name.capitalized,
                domain: domain ?? "General",
                tier: currentTier,
                isAvailable: available,
                model: model ?? "sonnet",
                triggers: triggers
            ))
        }

        agents = parsed
    }

    // MARK: - Compile Agent

    /// Compile an agent's identity. Returns the compiled system prompt text.
    func compile(agentId: String, mode: String = "craft") async -> String? {
        let output = await runAsync([compilePath, agentId, "--dispatch", "--mode", mode])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Dispatch to Agent

    /// Compile the agent's identity, then dispatch with it as the system prompt.
    /// Returns the dispatch stream for output tracking.
    func dispatchToAgent(
        agentId: String,
        message: String,
        project: String,
        workingDirectory: String,
        model: String?,
        mode: String = "craft"
    ) async -> AsyncStream<BridgeEvent> {
        // Compile agent identity
        let identity = await compile(agentId: agentId, mode: mode)

        let systemPrompt: String
        if let identity {
            systemPrompt = identity + "\n\nYou are dispatched through World Tree to work on project: \(project)."
        } else {
            systemPrompt = "You are \(agentId.capitalized), a Starfleet crew member dispatched through World Tree to work on project: \(project)."
        }

        let resolvedModel = model ?? agents.first(where: { $0.id == agentId })?.model ?? "sonnet"

        return ClaudeBridge.shared.dispatch(
            message: message,
            project: project,
            workingDirectory: workingDirectory,
            model: resolvedModel,
            origin: .crew,
            systemPrompt: systemPrompt
        )
    }

    // MARK: - Config Parsing

    /// Simple line-based YAML extraction for a single agent block.
    private func parseAgentConfig(name: String, from yaml: String) -> (String?, String?, String?, [String]) {
        let lines = yaml.components(separatedBy: "\n")
        var inBlock = false
        var displayName: String?
        var domain: String?
        var model: String?
        var triggers: [String] = []

        for line in lines {
            // Detect agent block start: "  agentname:" at 2-space indent
            if line.hasPrefix("  \(name):") && !line.hasPrefix("    ") {
                inBlock = true
                continue
            }

            // Exit block on next same-level key
            if inBlock && line.hasPrefix("  ") && !line.hasPrefix("    ") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }

            guard inBlock else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                displayName = extractYAMLValue(trimmed, key: "name")
            } else if trimmed.hasPrefix("domain:") {
                domain = extractYAMLValue(trimmed, key: "domain")
            } else if trimmed.hasPrefix("model:") {
                model = extractYAMLValue(trimmed, key: "model")
            } else if trimmed.hasPrefix("triggers:") {
                // Parse inline array: ["foo", "bar"]
                if let bracket = trimmed.range(of: "["),
                   let end = trimmed.range(of: "]") {
                    let inner = trimmed[bracket.upperBound..<end.lowerBound]
                    triggers = inner
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                        .filter { !$0.isEmpty }
                }
            }
        }

        return (displayName, domain, model, triggers)
    }

    private func extractYAMLValue(_ line: String, key: String) -> String? {
        guard let colonIdx = line.range(of: ":") else { return nil }
        let value = line[colonIdx.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }

    // MARK: - Process Helpers

    nonisolated private func runSync(_ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(home)/.cortana/bin:\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            wtLog("[StarfleetRoster] Failed to run \(args.first ?? "?"): \(error)")
            return ""
        }
    }

    nonisolated private func runAsync(_ args: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.runSync(args)
                continuation.resume(returning: result)
            }
        }
    }
}

// MARK: - StarfleetAgent Model

struct StarfleetAgent: Identifiable, Hashable {
    let id: String              // e.g. "geordi"
    let displayName: String     // e.g. "Geordi"
    let domain: String          // e.g. "Software Architecture"
    let tier: Tier
    let isAvailable: Bool
    let model: String           // default model for this agent
    let triggers: [String]      // keywords that route to this agent

    enum Tier: String, Hashable {
        case core
        case reserve
    }

    var icon: String {
        switch id {
        case "spock":   return "brain.head.profile"
        case "geordi":  return "building.columns"
        case "data":    return "paintbrush"
        case "worf":    return "shield.checkered"
        case "uhura":   return "text.bubble"
        case "torres":  return "gauge.with.dots.needle.67percent"
        case "dax":     return "books.vertical"
        case "kim":     return "doc.text"
        case "obrien":  return "wrench.and.screwdriver"
        case "scotty":  return "hammer"
        case "troi":    return "heart"
        case "seven":   return "magnifyingglass"
        case "odo":     return "scalemass"
        case "quark":   return "storefront"
        case "paris":   return "gamecontroller"
        case "sato":    return "globe"
        default:        return "person.circle"
        }
    }

    var tierColor: SwiftUI.Color {
        switch tier {
        case .core: return .cyan
        case .reserve: return .purple
        }
    }

    var agentColor: SwiftUI.Color {
        switch id {
        case "spock":   return .indigo
        case "geordi":  return .blue
        case "data":    return .cyan
        case "worf":    return .red
        case "uhura":   return .mint
        case "torres":  return .purple
        case "dax":     return .teal
        case "kim":     return .green
        case "obrien":  return .yellow
        case "scotty":  return .orange
        case "troi":    return .pink
        case "seven":   return .purple
        case "odo":     return .gray
        case "quark":   return .orange
        case "paris":   return .blue
        case "sato":    return .teal
        default:        return .secondary
        }
    }
}
