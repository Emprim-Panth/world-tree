import Foundation

enum ModelProviderFamily: Equatable {
    case claude
    case codex
}

struct ProviderModelOption: Identifiable, Equatable {
    let id: String
    let label: String
    let badge: String
    let description: String
    let providerFamily: ModelProviderFamily
}

enum ModelCatalog {
    private static let claudeProviderIds: Set<String> = ["claude-code", "anthropic-api"]

    private static let claudeModels: [ProviderModelOption] = [
        ProviderModelOption(
            id: "claude-sonnet-4-6",
            label: "Sonnet",
            badge: "S",
            description: "Balanced - fast, capable, default",
            providerFamily: .claude
        ),
        ProviderModelOption(
            id: "claude-opus-4-6",
            label: "Opus",
            badge: "O",
            description: "Deep - complex reasoning, slower",
            providerFamily: .claude
        ),
        ProviderModelOption(
            id: "claude-haiku-4-5-20251001",
            label: "Haiku",
            badge: "H",
            description: "Fast - quick tasks, lightest",
            providerFamily: .claude
        ),
    ]

    private static let codexModels: [ProviderModelOption] = [
        ProviderModelOption(
            id: "codex",
            label: "Codex",
            badge: "C",
            description: "OpenAI Codex via local CLI",
            providerFamily: .codex
        ),
    ]

    static func models(for providerId: String) -> [ProviderModelOption] {
        switch providerId {
        case "codex-cli":
            return codexModels
        default:
            return claudeModels
        }
    }

    static func defaultModel(for providerId: String) -> String {
        models(for: providerId).first?.id ?? AppConstants.defaultModel
    }

    static func availableModels(for providerIds: [String]) -> [ProviderModelOption] {
        var available: [ProviderModelOption] = []

        if providerIds.contains(where: isClaudeProvider) {
            available += claudeModels
        }

        if providerIds.contains("codex-cli") {
            available += codexModels
        }

        return available
    }

    static func isCompatible(_ modelId: String, with providerId: String) -> Bool {
        models(for: providerId).contains { $0.id == modelId }
    }

    static func resolveCompatibleModel(_ modelId: String?, providerId: String) -> String {
        guard let modelId, isCompatible(modelId, with: providerId) else {
            return defaultModel(for: providerId)
        }
        return modelId
    }

    static func ensureCompatibleDefaultModel(forProviderId providerId: String) {
        let defaults = UserDefaults.standard
        let current = defaults.string(forKey: AppConstants.defaultModelKey)
        let resolved = resolveCompatibleModel(current, providerId: providerId)
        if current != resolved {
            defaults.set(resolved, forKey: AppConstants.defaultModelKey)
        }
    }

    static func option(for modelId: String) -> ProviderModelOption? {
        (claudeModels + codexModels).first { $0.id == modelId }
    }

    static func canonicalModelId(for modelId: String?) -> String? {
        guard let raw = modelId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }

        if option(for: raw) != nil {
            return raw
        }

        switch raw.lowercased() {
        case "haiku":
            return "claude-haiku-4-5-20251001"
        case "sonnet":
            return "claude-sonnet-4-6"
        case "opus":
            return "claude-opus-4-6"
        case "codex":
            return "codex"
        default:
            return raw
        }
    }

    static func family(for modelId: String) -> ModelProviderFamily? {
        option(for: canonicalModelId(for: modelId) ?? modelId)?.providerFamily
    }

    static func preferredProviderId(
        for modelId: String,
        availableProviderIds: [String],
        currentProviderId: String? = nil,
        preferredClaudeProviderId: String? = nil
    ) -> String? {
        guard let option = option(for: modelId) else {
            return nil
        }

        switch option.providerFamily {
        case .codex:
            return availableProviderIds.contains("codex-cli") ? "codex-cli" : nil

        case .claude:
            if let preferredClaudeProviderId,
               availableProviderIds.contains(preferredClaudeProviderId) {
                return preferredClaudeProviderId
            }

            if let currentProviderId,
               isClaudeProvider(currentProviderId),
               availableProviderIds.contains(currentProviderId) {
                return currentProviderId
            }

            if availableProviderIds.contains("claude-code") {
                return "claude-code"
            }

            if availableProviderIds.contains("anthropic-api") {
                return "anthropic-api"
            }

            return nil
        }
    }

    static func label(for modelId: String) -> String {
        option(for: modelId)?.label ?? modelId
    }

    private static func isClaudeProvider(_ providerId: String) -> Bool {
        claudeProviderIds.contains(providerId)
    }
}
