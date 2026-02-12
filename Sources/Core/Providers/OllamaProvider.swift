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
        // Ping Ollama API to see if it's running
        guard let url = URL(string: "http://localhost:11434/api/tags") else {
            return .unavailable(reason: "Invalid Ollama URL")
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return .available
            }
            return .unavailable(reason: "Ollama not responding")
        } catch {
            return .unavailable(reason: "Ollama not running")
        }
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
