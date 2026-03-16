import Foundation

// MARK: - Route

enum SlashCommandRoute {
    /// Spawn a background job via CortanaWorkflowDispatchService.
    case dispatch
    /// Expand and inject as a user message inline (normal conversation turn).
    case injectConversation
}

// MARK: - Command

struct SlashCommand: Identifiable {
    let trigger: String          // e.g. "/plan"
    let displayName: String
    let description: String
    let route: SlashCommandRoute
    /// Transforms the raw input (e.g. "/plan foo") into the full prompt to send.
    let expandedPrompt: (String) -> String

    var id: String { trigger }
}

// MARK: - Registry

struct SlashCommandRegistry {

    static let all: [SlashCommand] = [
        SlashCommand(
            trigger: "/plan",
            displayName: "Plan",
            description: "Scope and plan a task",
            route: .dispatch,
            expandedPrompt: { input in
                let args = input.dropFirst("/plan".count).trimmingCharacters(in: .whitespaces)
                return args.isEmpty
                    ? "Scope and plan the current task."
                    : "Scope and plan this task: \(args)"
            }
        ),
        SlashCommand(
            trigger: "/next",
            displayName: "Next",
            description: "What's the next task to work on?",
            route: .injectConversation,
            expandedPrompt: { _ in
                "What's the next task to work on in this project?"
            }
        ),
        SlashCommand(
            trigger: "/verify",
            displayName: "Verify",
            description: "Verify the last implementation",
            route: .dispatch,
            expandedPrompt: { _ in
                "Verify the last implementation: check correctness, edge cases, and quality."
            }
        ),
        SlashCommand(
            trigger: "/scope",
            displayName: "Scope",
            description: "Scope this work",
            route: .injectConversation,
            expandedPrompt: { input in
                let args = input.dropFirst("/scope".count).trimmingCharacters(in: .whitespaces)
                return args.isEmpty
                    ? "Scope the current work."
                    : "Scope this work: \(args)"
            }
        ),
        SlashCommand(
            trigger: "/commit",
            displayName: "Commit",
            description: "Prepare a commit for staged changes",
            route: .dispatch,
            expandedPrompt: { _ in
                "Prepare a commit for the current staged changes with a descriptive message."
            }
        ),
        SlashCommand(
            trigger: "/why",
            displayName: "Why",
            description: "Explain why",
            route: .injectConversation,
            expandedPrompt: { input in
                let args = input.dropFirst("/why".count).trimmingCharacters(in: .whitespaces)
                return args.isEmpty
                    ? "Explain the rationale behind the last decision."
                    : "Explain why: \(args)"
            }
        ),
    ]

    /// Returns the command whose trigger matches the start of `input`, or nil.
    static func match(_ input: String) -> SlashCommand? {
        let lowered = input.lowercased()
        return all.first { cmd in
            // Accept exact match ("/plan") or trigger followed by a space ("/plan foo")
            lowered == cmd.trigger || lowered.hasPrefix(cmd.trigger + " ")
        }
    }

    /// Returns all commands whose trigger starts with the given prefix.
    static func suggestions(for prefix: String) -> [SlashCommand] {
        guard prefix.hasPrefix("/") else { return [] }
        let lowered = prefix.lowercased()
        return all.filter { $0.trigger.hasPrefix(lowered) }
    }
}
