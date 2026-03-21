import Foundation
import SwiftUI

// MARK: - Factory Pipeline Models

struct FactoryProject: Codable, Identifiable, Sendable {
    let id: String
    let intakePrompt: String
    var projectName: String?
    var projectPath: String?
    var state: FactoryState
    var blocked: Bool
    var blockedReason: String?
    var humanQuestion: String?
    var humanAnswer: String?
    let createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case intakePrompt     = "intake_prompt"
        case projectName      = "project_name"
        case projectPath      = "project_path"
        case state
        case blocked
        case blockedReason    = "blocked_reason"
        case humanQuestion    = "human_question"
        case humanAnswer      = "human_answer"
        case createdAt        = "created_at"
        case updatedAt        = "updated_at"
    }
}

enum FactoryState: String, Codable, CaseIterable, Sendable {
    case intake   = "INTAKE"
    case research = "RESEARCH"
    case design   = "DESIGN"
    case plan     = "PLAN"
    case code     = "CODE"
    case test     = "TEST"
    case submit   = "SUBMIT"
    case done     = "DONE"

    var displayName: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .intake:   return .gray
        case .research: return .blue
        case .design:   return .purple
        case .plan:     return .orange
        case .code:     return .cyan
        case .test:     return .yellow
        case .submit:   return .mint
        case .done:     return .green
        }
    }

    var icon: String {
        switch self {
        case .intake:   return "tray.and.arrow.down"
        case .research: return "magnifyingglass"
        case .design:   return "pencil.and.ruler"
        case .plan:     return "list.bullet.clipboard"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        case .test:     return "checkmark.shield"
        case .submit:   return "paperplane"
        case .done:     return "checkmark.circle.fill"
        }
    }

    /// All stages in pipeline order — used for progress visualization.
    static var pipelineOrder: [FactoryState] {
        [.intake, .research, .design, .plan, .code, .test, .submit, .done]
    }

    /// Zero-based index in pipeline order.
    var pipelineIndex: Int {
        Self.pipelineOrder.firstIndex(of: self) ?? 0
    }
}

// MARK: - Crew Session Models

struct NERVECrewSession: Codable, Identifiable, Sendable {
    let id: String
    let agent: String
    var status: String      // running, completed, failed, waiting
    var waitingFor: String?
    let task: String
    let model: String
    let startedAt: String
    var completedAt: String?
    var resultSummary: String?

    enum CodingKeys: String, CodingKey {
        case id
        case agent
        case status
        case waitingFor       = "waiting_for"
        case task
        case model
        case startedAt        = "started_at"
        case completedAt      = "completed_at"
        case resultSummary    = "result_summary"
    }

    var agentIcon: String {
        switch agent.lowercased() {
        case "geordi":  return "wrench.and.screwdriver"
        case "data":    return "chart.bar"
        case "scotty":  return "hammer"
        case "worf":    return "shield"
        case "torres":  return "gearshape.2"
        case "spock":   return "brain"
        case "dax":     return "book"
        case "uhura":   return "antenna.radiowaves.left.and.right"
        case "seven":   return "eye"
        case "obrien":  return "wrench"
        case "kim":     return "doc.text"
        case "quark":   return "chart.line.uptrend.xyaxis"
        default:        return "person.circle"
        }
    }

    var statusColor: Color {
        switch status {
        case "running":   return .cyan
        case "completed": return .green
        case "failed":    return .red
        case "waiting":   return .orange
        default:          return .gray
        }
    }
}

// MARK: - NERVE SSE Event

struct NERVEEvent: Codable, Sendable {
    let eventType: String
    /// Simplified payload — full AnyCodable avoided; parse typed fields as needed per event type.
    let payload: [String: String]
    let timestamp: Int64?

    enum CodingKeys: String, CodingKey {
        case eventType  = "event_type"
        case payload
        case timestamp
    }
}

// MARK: - NERVE API Response Wrappers

struct NERVEFactoryListResponse: Codable {
    let projects: [FactoryProject]
}

struct NERVECrewSessionListResponse: Codable {
    let sessions: [NERVECrewSession]

    enum CodingKeys: String, CodingKey {
        case sessions = "crew_sessions"
    }
}

/// Minimal system health response shape — expand as NERVE v2 endpoints stabilise.
struct NERVEHealthResponse: Codable {
    let status: String
    let version: String?
}
