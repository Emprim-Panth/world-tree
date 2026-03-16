import Foundation

// MARK: - Proposed Work Artifact

/// Structured description of a complex or risky action that requires explicit sign-off
/// before execution begins. Surfaced inline in the conversation as a proposal card.
///
/// Created by ToolExecutor for high-risk bash commands, or by CortanaWorkflowPlanner
/// when a multi-step plan is routed before dispatch.
struct ProposedWorkArtifact: Identifiable, Sendable {
    let id = UUID()

    // MARK: - Core Description
    let goal: String
    let steps: [String]

    // MARK: - Routing
    let primaryModel: String
    let reviewer: String?

    // MARK: - Scope
    let projectScope: String?
    let affectedFiles: [String]

    // MARK: - Risk
    let riskLevel: RiskLevel
    let accessMode: AccessMode

    // MARK: - Source
    let sourceCommand: String?
    let createdAt: Date

    // MARK: - Enums

    enum RiskLevel: String, Sendable {
        case low     = "Low"
        case medium  = "Medium"
        case high    = "High"

        var color: String {
            switch self {
            case .low:    return "green"
            case .medium: return "orange"
            case .high:   return "red"
            }
        }

        var icon: String {
            switch self {
            case .low:    return "checkmark.shield"
            case .medium: return "exclamationmark.shield"
            case .high:   return "exclamationmark.triangle"
            }
        }
    }

    enum AccessMode: String, Sendable {
        case readOnly   = "Read-only"
        case designOnly = "Design-only"
        case writeCapable = "Write-capable"

        var icon: String {
            switch self {
            case .readOnly:    return "eye"
            case .designOnly:  return "paintbrush"
            case .writeCapable: return "pencil"
            }
        }
    }

    // MARK: - Factory

    /// Build a proposal artifact from a resolved workflow plan, so the user can
    /// review routing + risk before any execution begins.
    static func fromWorkflowPlan(
        goal: String,
        steps: [String] = [],
        plan: CortanaWorkflowExecutionPlan,
        projectScope: String? = nil,
        riskLevel: RiskLevel = .medium,
        accessMode: AccessMode = .writeCapable
    ) -> ProposedWorkArtifact {
        ProposedWorkArtifact(
            goal: goal,
            steps: steps,
            primaryModel: plan.primaryModelId,
            reviewer: plan.reviewer?.modelId,
            projectScope: projectScope,
            affectedFiles: [],
            riskLevel: riskLevel,
            accessMode: accessMode,
            sourceCommand: nil,
            createdAt: Date()
        )
    }

    static func fromToolAssessment(
        assessment: ToolGuard.Assessment,
        command: String,
        primaryModel: String
    ) -> ProposedWorkArtifact {
        // Infer risk from the assessment
        let risk: RiskLevel
        switch assessment.riskLevel {
        case .safe:        risk = .low
        case .caution:     risk = .medium
        case .destructive, .critical: risk = .high
        }

        // Extract first line as goal, rest as context
        let lines = command.split(separator: "\n", omittingEmptySubsequences: true)
        let goal = String(lines.first ?? Substring(command.prefix(80)))
        let steps = lines.dropFirst().prefix(5).map(String.init)

        return ProposedWorkArtifact(
            goal: goal,
            steps: steps.isEmpty ? [command] : steps,
            primaryModel: primaryModel,
            reviewer: nil,
            projectScope: nil,
            affectedFiles: [],
            riskLevel: risk,
            accessMode: .writeCapable,
            sourceCommand: command,
            createdAt: Date()
        )
    }
}

// MARK: - Proposal Request

/// Suspend-until-reviewed request for a complex action proposal.
struct ProposalRequest: Identifiable {
    let id: UUID
    let artifact: ProposedWorkArtifact
    let continuation: CheckedContinuation<ProposalDecision, Never>

    init(artifact: ProposedWorkArtifact, continuation: CheckedContinuation<ProposalDecision, Never>) {
        self.id = UUID()
        self.artifact = artifact
        self.continuation = continuation
    }
}

enum ProposalDecision: Sendable {
    case approved
    case rejected
    case revised(String)   // Revised goal text for re-routing
}
