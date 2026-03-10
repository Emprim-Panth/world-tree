import Foundation
import Observation

// MARK: - Crew Models

struct CrewJob: Identifiable, Decodable {
    let id: String
    let project: String
    let model: String
    let crewAgent: String
    let prompt: String
    let ticketId: String?
    let status: String
    let attempts: Int
    let maxAttempts: Int
    let lastError: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, project, model, status, attempts, prompt
        case crewAgent   = "crew_agent"
        case ticketId    = "ticket_id"
        case maxAttempts = "max_attempts"
        case lastError   = "last_error"
        case createdAt   = "created_at"
    }

    var shortPrompt: String {
        let first = prompt.components(separatedBy: "\n").first ?? prompt
        return first.count > 90 ? String(first.prefix(90)) + "…" : first
    }

    var statusColor: String {
        switch status {
        case "running":   return "blue"
        case "pending":   return "orange"
        case "completed": return "green"
        case "failed":    return "red"
        default:          return "gray"
        }
    }

    var agentInitial: String { String(crewAgent.prefix(1)).uppercased() }
}

struct CrewHeartbeat: Decodable {
    let intensity: String
    let startedAt: String?
    let signalsFound: Int
    let dispatchesMade: Int
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case intensity, summary
        case startedAt      = "started_at"
        case signalsFound   = "signals_found"
        case dispatchesMade = "dispatches_made"
    }
}

struct CrewGovernance: Identifiable, Decodable {
    let id: String
    let category: String
    let content: String
    let project: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, category, content, project
        case createdAt = "created_at"
    }

    var shortContent: String {
        let first = content.components(separatedBy: "\n").first ?? content
        return first.count > 100 ? String(first.prefix(100)) + "…" : first
    }
}

struct CrewActivityPayload: Decodable {
    let dispatches: [CrewJob]
    let heartbeat: CrewHeartbeat?
    let governance: [CrewGovernance]
}

// MARK: - CrewStore

@Observable
@MainActor
final class CrewStore {
    var jobs: [CrewJob] = []
    var heartbeat: CrewHeartbeat?
    var governance: [CrewGovernance] = []
    var isLoading = false
    var lastError: String?
    var lastUpdated: Date?

    var activeJobs: [CrewJob] { jobs.filter { $0.status == "running" || $0.status == "pending" } }
    var doneJobs:   [CrewJob] { jobs.filter { $0.status == "completed" || $0.status == "failed" } }

    func fetch(server: SavedServer) async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let urlString = "http://\(server.host):\(server.port)/api/crew"
        guard let url = URL(string: urlString) else {
            lastError = "Invalid server URL"
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = "Server returned \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                return
            }
            let payload = try JSONDecoder().decode(CrewActivityPayload.self, from: data)
            jobs = payload.dispatches
            heartbeat = payload.heartbeat
            governance = payload.governance
            lastUpdated = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
