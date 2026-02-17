import Foundation
import Combine

// MARK: - Provider Manager

/// Orchestrates LLM providers — selection, fallback, and health monitoring.
/// Singleton accessed by ClaudeBridge as the routing layer.
@MainActor
final class ProviderManager: ObservableObject {
    static let shared = ProviderManager()

    /// All registered providers
    @Published private(set) var providers: [any LLMProvider] = []

    /// Currently selected provider identifier (persisted to UserDefaults)
    @Published var selectedProviderId: String {
        didSet {
            UserDefaults.standard.set(selectedProviderId, forKey: "cortana.selectedProvider")
        }
    }

    /// Health status for each provider (keyed by identifier)
    @Published private(set) var healthStatus: [String: ProviderHealth] = [:]

    private init() {
        self.selectedProviderId = UserDefaults.standard.string(forKey: "cortana.selectedProvider")
            ?? CortanaConstants.defaultProvider

        registerProviders()
    }

    // MARK: - Active Provider

    /// The currently selected provider, falling back to first available.
    var activeProvider: (any LLMProvider)? {
        providers.first { $0.identifier == selectedProviderId }
            ?? providers.first
    }

    /// Human-readable name of the active provider for UI display
    var activeProviderName: String {
        activeProvider?.displayName ?? "None"
    }

    /// Short badge label for the header ("Max" / "API" / "Local" / "Remote")
    var activeProviderBadge: String {
        switch activeProvider?.identifier {
        case "claude-code": return "Max"
        case "anthropic-api": return "API"
        case "ollama": return "Local"
        case "remote-canvas": return "Remote"
        default: return "?"
        }
    }

    // MARK: - Send

    func send(context: ProviderSendContext) -> AsyncStream<BridgeEvent> {
        guard let provider = activeProvider else {
            return AsyncStream { continuation in
                continuation.yield(.error("No LLM provider available"))
                continuation.finish()
            }
        }

        canvasLog("[ProviderManager] Routing to \(provider.displayName) (\(provider.identifier))")
        return provider.send(context: context)
    }

    func cancel() {
        activeProvider?.cancel()
    }

    var isRunning: Bool {
        activeProvider?.isRunning ?? false
    }

    // MARK: - Health

    /// Refresh health status for all providers
    func refreshHealth() async {
        for provider in providers {
            let health = await provider.checkHealth()
            healthStatus[provider.identifier] = health
        }
    }

    // MARK: - Registration

    private func registerProviders() {
        // 1. Claude Code (CLI + Max subscription) — always available
        let cliProvider = ClaudeCodeProvider()
        providers.append(cliProvider)

        // 2. Anthropic API — only if an API key exists
        if let apiKey = Self.resolveAPIKey() {
            canvasLog("[ProviderManager] API key found, registering Anthropic API provider")
            let apiProvider = AnthropicAPIProvider(apiKey: apiKey)
            providers.append(apiProvider)
        }

        // 3. Ollama (stub) — always registered for future use
        let ollamaProvider = OllamaProvider()
        providers.append(ollamaProvider)

        // 4. Remote Canvas — if remote mode was enabled in a previous session
        if UserDefaults.standard.bool(forKey: CortanaConstants.remoteCanvasEnabledKey) {
            if let remote = Self.buildRemoteProvider() {
                canvasLog("[ProviderManager] Remote mode was enabled, registering Remote Canvas provider")
                providers.append(remote)
                // Restore remote as active if it was previously selected
                if selectedProviderId == "remote-canvas" {
                    canvasLog("[ProviderManager] Restoring remote-canvas as active provider")
                }
            }
        }

        canvasLog("[ProviderManager] Registered \(providers.count) providers, active: \(selectedProviderId)")
    }

    // MARK: - Remote Provider Management

    /// Enable remote mode: registers RemoteCanvasProvider and switches to it.
    func enableRemoteProvider(url: URL, token: String) {
        // Remove any existing remote provider first
        providers.removeAll { $0.identifier == "remote-canvas" }

        let remote = RemoteCanvasProvider(serverURL: url, token: token)
        providers.append(remote)
        selectedProviderId = "remote-canvas"
        canvasLog("[ProviderManager] Remote Canvas enabled → \(url)")
    }

    /// Disable remote mode: removes RemoteCanvasProvider and falls back to Claude Code.
    func disableRemoteProvider() {
        providers.removeAll { $0.identifier == "remote-canvas" }
        if selectedProviderId == "remote-canvas" {
            selectedProviderId = CortanaConstants.defaultProvider
        }
        canvasLog("[ProviderManager] Remote Canvas disabled")
    }

    private static func buildRemoteProvider() -> RemoteCanvasProvider? {
        let urlString = UserDefaults.standard.string(forKey: CortanaConstants.remoteCanvasURLKey) ?? ""
        let token = UserDefaults.standard.string(forKey: CortanaConstants.remoteCanvasTokenKey) ?? ""
        guard !urlString.isEmpty, !token.isEmpty, let url = URL(string: urlString) else {
            return nil
        }
        return RemoteCanvasProvider(serverURL: url, token: token)
    }

    /// Resolve API key from environment or file (non-blocking).
    /// Avoids launchctl on startup since it would block MainActor.
    private static func resolveAPIKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return key
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let keyFile = "\(home)/.anthropic/api_key"
        if let key = try? String(contentsOfFile: keyFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }

        return nil
    }
}
