import Foundation
import GRDB

@MainActor
@Observable
final class CommandCenterViewModel {
    var compassProjects: [CompassState] = []
    var activeDispatches: [WorldTreeDispatch] = []
    var recentDispatches: [WorldTreeDispatch] = []
    var pendingHandoffs: [Handoff] = []
    var isShowingDispatchSheet = false

    private var observationTask: Task<Void, Never>?
    private var handoffTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func startObserving() {
        guard observationTask == nil else { return }

        refreshProjects()

        // Refresh project/ticket/compass state every 2 minutes
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { break }
                self?.refreshProjects()
            }
        }

        // Reactive observation of dispatches
        observationTask = Task { [weak self] in
            guard let dbPool = DatabaseManager.shared.dbPool else { return }

            let observation = ValueObservation.trackingConstantRegion { db -> ([WorldTreeDispatch], [WorldTreeDispatch]) in
                let active = try WorldTreeDispatch
                    .filter(Column("status") == "queued" || Column("status") == "running")
                    .order(Column("created_at").desc)
                    .fetchAll(db)

                let recent = try WorldTreeDispatch
                    .filter(Column("status") == "completed" || Column("status") == "failed")
                    .order(Column("completed_at").desc)
                    .limit(20)
                    .fetchAll(db)

                return (active, recent)
            }

            do {
                for try await (active, recent) in observation.values(in: dbPool) {
                    self?.activeDispatches = active
                    self?.recentDispatches = recent
                }
            } catch {
                // Observation cancelled or DB unavailable
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel(); observationTask = nil
        refreshTask?.cancel(); refreshTask = nil
        handoffTask?.cancel(); handoffTask = nil
    }

    // MARK: - Data Loading

    func refreshProjects() {
        CompassStore.shared.refresh()
        TicketStore.shared.scanAll()
        HeartbeatStore.shared.refresh()

        // Sort projects: attention score descending, then alphabetical
        compassProjects = CompassStore.shared.states.values.sorted {
            if $0.attentionScore != $1.attentionScore { return $0.attentionScore > $1.attentionScore }
            return $0.project < $1.project
        }
    }

    func refreshHandoffs() {
        handoffTask?.cancel()
        handoffTask = Task { [weak self] in
            guard let gateway = GatewayClient.fromLocalConfig() else { return }
            guard let handoffs = try? await gateway.checkHandoffs() else { return }
            self?.pendingHandoffs = handoffs.filter { $0.status == "pending" || $0.status == "created" }
        }
    }

    func dismissHandoff(_ id: String) {
        Task {
            guard let gateway = GatewayClient.fromLocalConfig() else { return }
            try? await gateway.updateHandoff(id: id, status: "viewed")
            pendingHandoffs.removeAll { $0.id == id }
        }
    }

    func pickUpHandoff(_ id: String) {
        Task {
            guard let gateway = GatewayClient.fromLocalConfig() else { return }
            try? await gateway.updateHandoff(id: id, status: "picked_up")
            pendingHandoffs.removeAll { $0.id == id }
        }
    }
}
