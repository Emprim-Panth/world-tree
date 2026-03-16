import Foundation

// MARK: - Ollama Provider

/// Local model provider via Ollama. Streams responses from a locally running Ollama server.
/// Install Ollama from ollama.com and run `ollama serve` to use this provider.
final class OllamaProvider: LLMProvider {
    let displayName = "Ollama (Local)"
    let identifier = "ollama"
    let capabilities: ProviderCapabilities = [.streaming, .modelSelection]

    private(set) var isRunning = false
    private var currentTask: Task<Void, Never>?

    // MARK: - Health Check

    func checkHealth() async -> ProviderHealth {
        let running = await OllamaClient.shared.isRunning()
        isRunning = running
        if running {
            let models = await OllamaClient.shared.availableModels()
            if models.isEmpty {
                return .degraded(reason: "Ollama running but no models installed — run 'ollama pull llama3.2'")
            }
            return .available
        }
        return .unavailable(reason: "Ollama not running — install from ollama.com and run 'ollama serve'")
    }

    // MARK: - Send

    func send(context: ProviderSendContext) -> AsyncStream<BridgeEvent> {
        AsyncStream { continuation in
            let model = context.model ?? "llama3.2"

            // Build message list
            var messages: [OllamaChatMessage] = []

            // Compose system prompt from available context
            var systemParts: [String] = []
            if let checkpoint = context.checkpointContext, !checkpoint.isEmpty {
                systemParts.append(checkpoint)
            }
            if let recent = context.recentContext, !recent.isEmpty {
                systemParts.append(recent)
            }
            if let override = context.systemPromptOverride, !override.isEmpty {
                systemParts.append(override)
            }
            if !systemParts.isEmpty {
                messages.append(OllamaChatMessage(role: "system", content: systemParts.joined(separator: "\n\n")))
            }

            messages.append(OllamaChatMessage(role: "user", content: context.message))

            let task = Task {
                do {
                    for try await chunk in await OllamaClient.shared.chatStream(model: model, messages: messages) {
                        if Task.isCancelled { break }
                        continuation.yield(.text(chunk))
                    }
                    continuation.yield(.done(usage: SessionTokenUsage()))
                } catch {
                    if !Task.isCancelled {
                        continuation.yield(.error(error.localizedDescription))
                    }
                }
                continuation.finish()
            }

            self.currentTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
    }
}
