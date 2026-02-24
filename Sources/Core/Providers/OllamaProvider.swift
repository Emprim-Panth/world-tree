import Foundation

// MARK: - Ollama Provider (Stub)

/// Future local model provider using Ollama.
/// Currently a stub — health check pings localhost:11434, send returns an error.
final class OllamaProvider: LLMProvider {
    let displayName = "Ollama (Local)"
    let identifier = "ollama"
    let capabilities: ProviderCapabilities = [.streaming, .modelSelection]

    private(set) var isRunning = false

    // MARK: - Health Check

    func checkHealth() async -> ProviderHealth {
        // Provider is not yet implemented — always report unavailable so it
        // cannot be selected in the picker until send() is implemented.
        return .unavailable(reason: "Ollama support coming soon")
    }

    // MARK: - Send

    func send(context: ProviderSendContext) -> AsyncStream<BridgeEvent> {
        AsyncStream { continuation in
            continuation.yield(.error("Ollama provider not yet implemented. Install Ollama and check back soon."))
            continuation.finish()
        }
    }

    func cancel() {
        // No-op for stub
    }
}
