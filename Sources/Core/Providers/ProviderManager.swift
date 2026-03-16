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
            UserDefaults.standard.set(selectedProviderId, forKey: AppConstants.selectedProviderKey)
            ModelCatalog.ensureCompatibleDefaultModel(forProviderId: selectedProviderId)
        }
    }

    /// Health status for each provider (keyed by identifier)
    @Published private(set) var healthStatus: [String: ProviderHealth] = [:]

    private init() {
        self.selectedProviderId = UserDefaults.standard.string(forKey: AppConstants.selectedProviderKey)
            ?? AppConstants.defaultProvider

        registerProviders()
        normalizeSelectedProvider()
        ModelCatalog.ensureCompatibleDefaultModel(forProviderId: selectedProviderId)
        Task { await refreshHealth() }
    }

    // MARK: - Active Provider

    private var chatProviders: [any LLMProvider] {
        providers.filter { $0.identifier != "agent-sdk" }
    }

    /// The currently selected provider, falling back to first available.
    var activeProvider: (any LLMProvider)? {
        chatProviders.first { $0.identifier == selectedProviderId }
            ?? chatProviders.first
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
        case "codex-cli": return "Codex"
        case "ollama": return "Local"
        case "remote-canvas": return "Remote"
        default: return "?"
        }
    }

    /// Providers safe to expose in the interactive settings UI.
    var selectableProviders: [any LLMProvider] {
        chatProviders
    }

    /// Provider IDs that can back a user-selectable model in the UI.
    var modelSelectableProviderIds: [String] {
        chatProviders
            .filter { $0.capabilities.contains(.modelSelection) }
            .map(\.identifier)
    }

    var availableModelOptions: [ProviderModelOption] {
        ModelCatalog.availableModels(for: modelSelectableProviderIds)
    }

    /// Look up a provider by identifier
    func provider(withId id: String) -> (any LLMProvider)? {
        providers.first { $0.identifier == id }
    }

    func preferredProviderId(forModelId modelId: String) -> String? {
        ModelCatalog.preferredProviderId(
            for: modelId,
            availableProviderIds: modelSelectableProviderIds,
            currentProviderId: selectedProviderId,
            preferredClaudeProviderId: preferredClaudeProviderIdForRouting()
        )
    }

    func makeEphemeralProvider(forModelId modelId: String) -> (any LLMProvider)? {
        guard let providerId = preferredProviderId(forModelId: modelId) else {
            return nil
        }

        switch providerId {
        case "claude-code":
            return ClaudeCodeProvider()
        case "anthropic-api":
            guard let apiKey = Self.resolveAPIKey() else { return nil }
            return AnthropicAPIProvider(apiKey: apiKey)
        case "codex-cli":
            return CodexCLIProvider()
        case "ollama":
            return OllamaProvider()
        default:
            return nil
        }
    }

    func selectModel(_ modelId: String) {
        if let providerId = ModelCatalog.preferredProviderId(
            for: modelId,
            availableProviderIds: modelSelectableProviderIds,
            currentProviderId: selectedProviderId,
            preferredClaudeProviderId: preferredClaudeProviderIdForRouting()
        ), providerId != selectedProviderId {
            selectedProviderId = providerId
        }

        UserDefaults.standard.set(modelId, forKey: AppConstants.defaultModelKey)
    }

    // MARK: - Send

    func send(context: ProviderSendContext) -> AsyncStream<BridgeEvent> {
        let route = routePreview(
            message: context.message,
            preferredModelId: context.model
                ?? UserDefaults.standard.string(forKey: AppConstants.defaultModelKey)
                ?? AppConstants.defaultModel
        )

        var routedContext = context
        routedContext.model = route.primaryModelId

        let providerId = ModelCatalog.preferredProviderId(
            for: route.primaryModelId,
            availableProviderIds: modelSelectableProviderIds,
            currentProviderId: selectedProviderId,
            preferredClaudeProviderId: preferredClaudeProviderIdForRouting()
        )

        guard let provider = providerId.flatMap(provider(withId:)) ?? activeProvider else {
            return AsyncStream { continuation in
                continuation.yield(.error("No LLM provider available"))
                continuation.finish()
            }
        }

        let reviewer = route.reviewerModelId.map(ModelCatalog.label(for:)) ?? "none"
        wtLog(
            "[ProviderManager] Routing to \(provider.displayName) (\(provider.identifier)), " +
            "model=\(route.primaryModelId), reviewer=\(reviewer), reason=\(route.reason)"
        )
        return provider.send(context: routedContext)
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
        providers.removeAll()

        // 1. Claude Code (CLI + Max subscription) — always available
        let cliProvider = ClaudeCodeProvider()
        providers.append(cliProvider)

        // 2. Agent SDK (Background dispatch) — always available alongside Claude Code
        let sdkProvider = AgentSDKProvider()
        providers.append(sdkProvider)

        // 3. Anthropic API — only if an API key exists
        if let apiKey = Self.resolveAPIKey() {
            wtLog("[ProviderManager] API key found, registering Anthropic API provider")
            let apiProvider = AnthropicAPIProvider(apiKey: apiKey)
            providers.append(apiProvider)
        }

        // 4. Codex CLI (OpenAI) — available when the CLI is installed
        if CodexCLIProvider.isInstalled() {
            providers.append(CodexCLIProvider())
        }

        // 5. Ollama (stub) — always registered for future use
        let ollamaProvider = OllamaProvider()
        providers.append(ollamaProvider)

        // 6. Remote Canvas — if remote mode was enabled in a previous session
        if UserDefaults.standard.bool(forKey: AppConstants.remoteEnabledKey) {
            if let remote = Self.buildRemoteProvider() {
                wtLog("[ProviderManager] Remote mode was enabled, registering Remote Studio provider")
                providers.append(remote)
                // Restore remote as active if it was previously selected
                if selectedProviderId == "remote-canvas" {
                    wtLog("[ProviderManager] Restoring remote-canvas as active provider")
                }
            }
        }

        wtLog("[ProviderManager] Registered \(providers.count) providers, active: \(selectedProviderId)")
    }

    func reloadProviders() {
        healthStatus.removeAll()
        registerProviders()
        normalizeSelectedProvider()
        ModelCatalog.ensureCompatibleDefaultModel(forProviderId: selectedProviderId)
    }

    func routePreview(message: String, preferredModelId: String? = nil) -> CortanaWorkflowRoute {
        let defaults = UserDefaults.standard
        let requestedModel = preferredModelId
            ?? defaults.string(forKey: AppConstants.defaultModelKey)
            ?? AppConstants.defaultModel
        let autoRoutingEnabled = defaults.object(forKey: AppConstants.cortanaAutoRoutingEnabledKey) as? Bool ?? false
        let crossCheckEnabled = defaults.object(forKey: AppConstants.cortanaCrossCheckEnabledKey) as? Bool ?? true
        let hasClaudeFamily = modelSelectableProviderIds.contains(where: Self.isClaudeProvider)
        let hasCodex = modelSelectableProviderIds.contains("codex-cli")

        return CortanaWorkflowRouter.plan(
            message: message,
            preferredModelId: requestedModel,
            autoRoutingEnabled: autoRoutingEnabled,
            crossCheckEnabled: crossCheckEnabled,
            hasClaudeFamily: hasClaudeFamily,
            hasCodex: hasCodex
        )
    }

    // MARK: - Remote Provider Management

    /// Enable remote mode: registers RemoteWorldTreeProvider and switches to it.
    func enableRemoteProvider(url: URL, token: String) {
        // Remove any existing remote provider first
        providers.removeAll { $0.identifier == "remote-canvas" }

        let remote = RemoteWorldTreeProvider(serverURL: url, token: token)
        providers.append(remote)
        selectedProviderId = "remote-canvas"
        wtLog("[ProviderManager] Remote Studio enabled → \(url)")
    }

    /// Disable remote mode: removes RemoteWorldTreeProvider and falls back to Claude Code.
    func disableRemoteProvider() {
        providers.removeAll { $0.identifier == "remote-canvas" }
        if selectedProviderId == "remote-canvas" {
            selectedProviderId = AppConstants.defaultProvider
        }
        wtLog("[ProviderManager] Remote Studio disabled")
    }

    private static func buildRemoteProvider() -> RemoteWorldTreeProvider? {
        let urlString = UserDefaults.standard.string(forKey: AppConstants.remoteURLKey) ?? ""
        let token = UserDefaults.standard.string(forKey: AppConstants.remoteTokenKey) ?? ""
        guard !urlString.isEmpty, !token.isEmpty, let url = URL(string: urlString) else {
            return nil
        }
        return RemoteWorldTreeProvider(serverURL: url, token: token)
    }

    /// Resolve API key from environment or file (non-blocking).
    /// Avoids launchctl on startup since it would block MainActor.
    private static func resolveAPIKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return key
        }

        if let key = KeychainHelper.load(key: "anthropic_api_key"), !key.isEmpty {
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

    private func normalizeSelectedProvider() {
        let availableIds = Set(chatProviders.map { $0.identifier })
        if availableIds.contains(selectedProviderId) {
            return
        }

        if availableIds.contains(AppConstants.defaultProvider) {
            selectedProviderId = AppConstants.defaultProvider
        } else if let fallback = chatProviders.first?.identifier {
            selectedProviderId = fallback
        }
    }

    private func preferredClaudeProviderIdForRouting() -> String? {
        let availableIds = Set(modelSelectableProviderIds)

        if availableIds.contains("anthropic-api"), selectedProviderId == "anthropic-api" {
            return "anthropic-api"
        }

        if availableIds.contains("claude-code"), claudeCodeUsableForRouting() {
            return "claude-code"
        }

        if availableIds.contains("anthropic-api") {
            return "anthropic-api"
        }

        if availableIds.contains("claude-code") {
            return "claude-code"
        }

        return nil
    }

    private func claudeCodeUsableForRouting() -> Bool {
        if let health = healthStatus["claude-code"] {
            return health.isUsable
        }

        return ClaudeCodeAuthProbe.currentStatus(timeout: 1.5).isUsable
    }

    private static func isClaudeProvider(_ providerId: String) -> Bool {
        ["claude-code", "anthropic-api"].contains(providerId)
    }
}
