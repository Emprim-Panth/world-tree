import Foundation
import Observation

// MARK: - FactoryStore

/// Observable store holding all Cortana 2.0 factory pipeline state.
/// Subscribes to NERVE SSE on `start()` and updates state from incoming events.
@MainActor
@Observable
final class FactoryStore {
    static let shared = FactoryStore()

    // MARK: Published State

    var factoryProjects: [FactoryProject]   = []
    var crewSessions:    [NERVECrewSession] = []
    var isConnected:     Bool               = false
    var connectionError: String?            = nil
    /// Non-nil when a system-level alert (disk pressure, crash detected) comes in via SSE.
    var systemAlert: SystemAlert?           = nil

    // MARK: Private

    private var sseTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Call once at app launch (e.g. in `WorldTreeApp.onAppear`).
    func start() async {
        await loadInitialState()
        startSSESubscription()
    }

    func stop() {
        sseTask?.cancel()
        sseTask = nil
        isConnected = false
    }

    // MARK: - Public Actions

    func submitProject(prompt: String) async throws {
        let project = try await NERVEClient.shared.createFactoryProject(prompt: prompt)
        // Append only if not already present (SSE may have delivered it first)
        if !factoryProjects.contains(where: { $0.id == project.id }) {
            factoryProjects.append(project)
        }
    }

    func answerQuestion(projectId: String, answer: String) async throws {
        try await NERVEClient.shared.answerFactoryQuestion(projectId: projectId, answer: answer)
        // Refresh the affected project from NERVE to get updated state
        await refreshProject(id: projectId)
    }

    func refresh() async {
        await loadInitialState()
    }

    // MARK: - Private

    private func loadInitialState() async {
        do {
            factoryProjects = try await NERVEClient.shared.fetchFactoryProjects()
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
        }
        // Crew sessions are supplementary — don't fail factory load if unavailable
        if let sessions = try? await NERVEClient.shared.fetchCrewSessions() {
            crewSessions = sessions
        }
    }

    private func startSSESubscription() {
        sseTask?.cancel()
        sseTask = NERVEClient.shared.subscribeToStream { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleNERVEEvent(event)
            }
        }
        // Treat subscription startup as connected — actual connectivity is confirmed by first event
        isConnected = true
    }

    private func handleNERVEEvent(_ event: NERVEEvent) {
        switch event.eventType {
        case "factory.state_changed", "factory.agent_question", "factory.project_created", "factory.project_complete":
            if let projectId = event.payload["factory_project_id"] ?? event.payload["project_id"] ?? event.payload["id"] {
                Task { await self.refreshProject(id: projectId) }
            } else {
                // No ID in payload — reload full list
                Task { await self.loadInitialState() }
            }

        case "crew.session_started", "crew.session_completed":
            Task { await self.refreshCrewSessions() }

        case "system.crash_detected":
            let message = event.payload["message"] ?? "A process crash was detected."
            systemAlert = SystemAlert(kind: .crash, message: message)

        case "system.disk_pressure":
            let message = event.payload["message"] ?? "Disk pressure above 85%."
            systemAlert = SystemAlert(kind: .diskPressure, message: message)

        case "system.service_down":
            let svc     = event.payload["service"] ?? "unknown"
            systemAlert = SystemAlert(kind: .serviceDown, message: "\(svc) stopped heartbeating.")

        default:
            break
        }
    }

    private func refreshProject(id: String) async {
        if let updated = try? await NERVEClient.shared.fetchFactoryProject(id: id) {
            if let idx = factoryProjects.firstIndex(where: { $0.id == id }) {
                factoryProjects[idx] = updated
            } else {
                factoryProjects.append(updated)
            }
        }
    }

    private func refreshCrewSessions() async {
        if let sessions = try? await NERVEClient.shared.fetchCrewSessions() {
            crewSessions = sessions
        }
    }
}

// MARK: - System Alert Model

struct SystemAlert: Identifiable {
    enum Kind {
        case crash
        case diskPressure
        case serviceDown

        var icon:  String { switch self { case .crash: "xmark.octagon.fill"; case .diskPressure: "internaldrive"; case .serviceDown: "wifi.slash" } }
        var color: String { switch self { case .crash, .serviceDown: "red"; case .diskPressure: "yellow" } }
    }

    let id    = UUID()
    let kind:    Kind
    let message: String
    let seenAt   = Date()
}
