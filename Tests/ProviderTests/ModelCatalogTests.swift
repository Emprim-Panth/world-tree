import XCTest
@testable import WorldTree

final class ModelCatalogTests: XCTestCase {
    func testAvailableModelsIncludeCodexWhenProviderIsInstalled() {
        let models = ModelCatalog.availableModels(for: ["claude-code", "codex-cli"]).map(\.id)

        XCTAssertEqual(
            models,
            ["claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5-20251001", "codex"]
        )
    }

    func testCodexProviderDefaultsToCodexModel() {
        XCTAssertEqual(ModelCatalog.defaultModel(for: "codex-cli"), "codex")
        XCTAssertEqual(ModelCatalog.resolveCompatibleModel(nil, providerId: "codex-cli"), "codex")
    }

    func testIncompatibleClaudeModelFallsBackForCodexProvider() {
        let resolved = ModelCatalog.resolveCompatibleModel(
            "claude-sonnet-4-6",
            providerId: "codex-cli"
        )

        XCTAssertEqual(resolved, "codex")
    }

    func testPreferredProviderUsesCodexForCodexModel() {
        let providerId = ModelCatalog.preferredProviderId(
            for: "codex",
            availableProviderIds: ["claude-code", "codex-cli"],
            currentProviderId: "claude-code"
        )

        XCTAssertEqual(providerId, "codex-cli")
    }

    func testPreferredProviderPreservesCurrentClaudeBackend() {
        let providerId = ModelCatalog.preferredProviderId(
            for: "claude-opus-4-6",
            availableProviderIds: ["claude-code", "anthropic-api", "codex-cli"],
            currentProviderId: "anthropic-api"
        )

        XCTAssertEqual(providerId, "anthropic-api")
    }

    func testPreferredProviderFallsBackToClaudeCodeForClaudeModels() {
        let providerId = ModelCatalog.preferredProviderId(
            for: "claude-sonnet-4-6",
            availableProviderIds: ["claude-code", "codex-cli"],
            currentProviderId: "codex-cli"
        )

        XCTAssertEqual(providerId, "claude-code")
    }

    func testPreferredProviderUsesAnthropicFallbackWhenRequested() {
        let providerId = ModelCatalog.preferredProviderId(
            for: "claude-sonnet-4-6",
            availableProviderIds: ["claude-code", "anthropic-api", "codex-cli"],
            currentProviderId: "claude-code",
            preferredClaudeProviderId: "anthropic-api"
        )

        XCTAssertEqual(providerId, "anthropic-api")
    }

    func testCanonicalModelIdNormalizesLegacyNames() {
        XCTAssertEqual(ModelCatalog.canonicalModelId(for: "sonnet"), "claude-sonnet-4-6")
        XCTAssertEqual(ModelCatalog.canonicalModelId(for: "opus"), "claude-opus-4-6")
        XCTAssertEqual(ModelCatalog.canonicalModelId(for: "haiku"), "claude-haiku-4-5-20251001")
        XCTAssertEqual(ModelCatalog.canonicalModelId(for: "codex"), "codex")
    }

    @MainActor
    func testAgentSDKIsNotSelectableAsInteractiveProvider() {
        let providerIds = ProviderManager.shared.selectableProviders.map { $0.identifier }
        XCTAssertFalse(providerIds.contains("agent-sdk"))
        XCTAssertTrue(providerIds.contains("claude-code"))
    }
}
