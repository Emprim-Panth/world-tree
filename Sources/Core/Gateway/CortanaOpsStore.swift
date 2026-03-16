import Foundation

@MainActor
final class CortanaOpsStore: ObservableObject {
    static let shared = CortanaOpsStore()

    @Published private(set) var agentEvents: [CortanaAgentEvent] = []
    @Published private(set) var attentionItems: [CortanaAttentionItem] = []
    @Published private(set) var lastError: String?

    private var refreshTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        guard let client = GatewayClient.fromLocalConfig() else {
            lastError = "Gateway auth token unavailable"
            return
        }

        do {
            async let events = client.listAgentEvents(source: "cortana.watchdog")
            async let attention = client.listAttentionQueue()
            let (resolvedEvents, resolvedAttention) = try await (events, attention)
            agentEvents = resolvedEvents
                .filter { $0.status == "open" }
                .sorted { $0.firstSeenAt > $1.firstSeenAt }
            attentionItems = resolvedAttention
                .filter { $0.status == "open" }
                .sorted { $0.createdAt > $1.createdAt }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            wtLog("[CortanaOpsStore] refresh failed: \(error)")
        }
    }

    func resolve(event: CortanaAgentEvent) {
        Task {
            guard let client = GatewayClient.fromLocalConfig() else { return }
            do {
                try await client.resolveAgentEvent(id: event.id, executedAction: "acknowledged in World Tree")
                await refresh()
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func resolveAttention(_ item: CortanaAttentionItem) {
        Task {
            guard let client = GatewayClient.fromLocalConfig() else { return }
            do {
                try await client.updateAttentionItem(id: item.id, status: "resolved")
                await refresh()
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }
}
