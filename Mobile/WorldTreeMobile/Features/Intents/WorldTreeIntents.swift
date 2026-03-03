import AppIntents
import Foundation

// MARK: - AppIntents (TASK-059)
//
// Exposes World Tree to Siri and the Shortcuts app.
//
// Available intents:
//   AskCortanaIntent      – "Hey Siri, ask Cortana about <topic>"
//   OpenWorldTreeIntent   – "Hey Siri, open World Tree"
//
// These are discovered automatically by the OS — no registration needed beyond
// conforming to AppIntent. Shortcuts app shows them in "World Tree" app section.

// MARK: - Ask Cortana

struct AskCortanaIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Cortana"
    static let description = IntentDescription("Send a message to Cortana in World Tree.")

    @Parameter(title: "Message", description: "What you want to ask Cortana.")
    var message: String

    /// Siri phrase: "Ask Cortana about the Archon-CAD deadline"
    static var parameterSummary: some ParameterSummary {
        Summary("Ask Cortana \(\.$message)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard var components = URLComponents(string: "worldtree://newbranch") else {
            throw IntentError.generic
        }
        components.queryItems = [URLQueryItem(name: "text", value: message)]
        guard let url = components.url else {
            throw IntentError.generic
        }
        if #available(iOS 18.0, *) {
            return .result(opensIntent: OpenURLIntent(url))
        }
        return .result()
    }
}

// MARK: - Open World Tree

struct OpenWorldTreeIntent: AppIntent {
    static let title: LocalizedStringResource = "Open World Tree"
    static let description = IntentDescription("Open World Tree and resume your last conversation.")

    /// Siri phrase: "Open World Tree"
    static var parameterSummary: some ParameterSummary {
        Summary("Open World Tree")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = URL(string: "worldtree://") else {
            throw IntentError.generic
        }
        if #available(iOS 18.0, *) {
            return .result(opensIntent: OpenURLIntent(url))
        }
        return .result()
    }
}

// MARK: - Shortcuts App Provider

struct WorldTreeShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskCortanaIntent(),
            phrases: [
                "Ask Cortana in \(.applicationName)",
                "Send a message in \(.applicationName)",
            ],
            shortTitle: "Ask Cortana",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: OpenWorldTreeIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Resume \(.applicationName)",
            ],
            shortTitle: "Open World Tree",
            systemImageName: "arrow.triangle.branch"
        )
    }
}

// MARK: - Intent Error

private enum IntentError: Error, LocalizedError {
    case generic
    var errorDescription: String? { "Unable to open World Tree. Please try again." }
}
