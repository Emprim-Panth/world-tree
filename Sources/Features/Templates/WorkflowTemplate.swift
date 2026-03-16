import Foundation

// MARK: - Workflow Templates

enum WorkflowReviewMode: String, Codable, Sendable {
    case none
    case qaChain
    case challenge

    var label: String {
        switch self {
        case .none:
            return "Single Pass"
        case .qaChain:
            return "QA Chain"
        case .challenge:
            return "Challenge"
        }
    }

    var runsAutomatically: Bool {
        self != .none
    }
}

/// Pre-built conversation structures for common dev tasks.
/// Templates define branch configuration, initial system context, and suggested prompts.
struct WorkflowTemplate: Identifiable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let branchType: BranchType
    let suggestedModel: String?
    let initialPrompt: String?
    let systemContext: String?
    let sandboxProfile: String  // "unrestricted", "workspace", "airgapped"
    let reviewMode: WorkflowReviewMode
    let recommendedAgentIds: [String]

    // MARK: - Built-in Templates

    static let all: [WorkflowTemplate] = [
        fastTriage,
        bugFix,
        featureImpl,
        implementReview,
        architectChallenge,
        codeReview,
        refactor,
        exploration,
        documentation,
        debugging,
    ]

    static let bugFix = WorkflowTemplate(
        id: "bug-fix",
        name: "Bug Fix",
        description: "Investigate and fix a bug with structured debugging approach",
        icon: "ladybug.fill",
        branchType: .implementation,
        suggestedModel: nil,
        initialPrompt: nil,
        systemContext: """
            Structured bug fix workflow:
            1. Reproduce the issue
            2. Identify root cause
            3. Implement minimal fix
            4. Verify fix works
            5. Check for regressions
            """,
        sandboxProfile: "workspace",
        reviewMode: .none,
        recommendedAgentIds: ["geordi", "worf"]
    )

    static let featureImpl = WorkflowTemplate(
        id: "feature-impl",
        name: "Feature Implementation",
        description: "Plan and implement a new feature with tests",
        icon: "star.fill",
        branchType: .implementation,
        suggestedModel: nil,
        initialPrompt: nil,
        systemContext: """
            Feature implementation workflow:
            1. Understand requirements
            2. Design approach (check existing patterns)
            3. Implement incrementally
            4. Write tests
            5. Build and verify
            """,
        sandboxProfile: "workspace",
        reviewMode: .none,
        recommendedAgentIds: ["geordi", "data"]
    )

    static let implementReview = WorkflowTemplate(
        id: "implement-review",
        name: "Implement + QA",
        description: "Build the feature, then queue a focused QA review before calling it done",
        icon: "checkmark.shield.fill",
        branchType: .implementation,
        suggestedModel: "codex",
        initialPrompt: nil,
        systemContext: """
            Delivery workflow:
            1. Understand the requested app or feature boundary
            2. Implement the smallest complete slice that works end-to-end
            3. Add or update tests while building
            4. Build and verify locally
            5. Hand off to the QA chain with explicit risks and changed files
            """,
        sandboxProfile: "workspace",
        reviewMode: .qaChain,
        recommendedAgentIds: ["geordi", "worf", "data"]
    )

    static let architectChallenge = WorkflowTemplate(
        id: "architect-challenge",
        name: "Architect + Challenge",
        description: "Plan with the deep-reasoning lane, then run a challenger pass against assumptions",
        icon: "triangle.2.circlepath.circle.fill",
        branchType: .exploration,
        suggestedModel: "claude-opus-4-6",
        initialPrompt: "Design the architecture, explain the tradeoffs, and identify the highest-risk assumptions before implementation starts.",
        systemContext: """
            Architecture workflow:
            1. Define the target outcome and constraints
            2. Propose the simplest viable architecture
            3. Name the tradeoffs explicitly
            4. Identify what could break under scale, complexity, or ambiguity
            5. Prepare the design for an adversarial challenge pass
            """,
        sandboxProfile: "unrestricted",
        reviewMode: .challenge,
        recommendedAgentIds: ["spock", "data", "geordi"]
    )

    static let fastTriage = WorkflowTemplate(
        id: "fast-triage",
        name: "Fast Triage",
        description: "Quick diagnosis, next step, and escalation path without a review chain",
        icon: "bolt.circle.fill",
        branchType: .conversation,
        suggestedModel: "claude-haiku-4-5-20251001",
        initialPrompt: "Triage the issue quickly. Identify the likely cause, the next diagnostic step, and whether this needs a deeper workflow.",
        systemContext: """
            Fast triage workflow:
            1. Identify the symptom
            2. Give the fastest useful next step
            3. Escalate only if the problem is larger than a quick pass can safely resolve
            """,
        sandboxProfile: "workspace",
        reviewMode: .none,
        recommendedAgentIds: ["geordi", "uhura"]
    )

    static let codeReview = WorkflowTemplate(
        id: "code-review",
        name: "Code Review",
        description: "Review code changes for quality, security, and correctness",
        icon: "eye.fill",
        branchType: .exploration,
        suggestedModel: nil,
        initialPrompt: "Review the recent changes in this project. Check for bugs, security issues, code quality, and suggest improvements.",
        systemContext: """
            Code review checklist:
            - Correctness: Does it do what it claims?
            - Security: OWASP top 10, input validation
            - Performance: O(n) concerns, unnecessary allocations
            - Readability: Clear names, reasonable complexity
            - Tests: Adequate coverage for changes
            """,
        sandboxProfile: "unrestricted",
        reviewMode: .challenge,
        recommendedAgentIds: ["worf", "data"]
    )

    static let refactor = WorkflowTemplate(
        id: "refactor",
        name: "Refactoring",
        description: "Restructure code while preserving behavior",
        icon: "arrow.triangle.2.circlepath",
        branchType: .implementation,
        suggestedModel: nil,
        initialPrompt: nil,
        systemContext: """
            Refactoring protocol:
            1. Identify what to refactor and why
            2. Ensure tests exist for current behavior
            3. Make incremental changes
            4. Run tests after each change
            5. Verify behavior is preserved
            """,
        sandboxProfile: "workspace",
        reviewMode: .none,
        recommendedAgentIds: ["geordi"]
    )

    static let exploration = WorkflowTemplate(
        id: "exploration",
        name: "Codebase Exploration",
        description: "Understand architecture, patterns, and dependencies",
        icon: "magnifyingglass.circle.fill",
        branchType: .exploration,
        suggestedModel: nil,
        initialPrompt: "Explore this codebase. Map out the architecture, identify key patterns, dependencies, and potential issues.",
        systemContext: nil,
        sandboxProfile: "unrestricted",
        reviewMode: .none,
        recommendedAgentIds: ["spock", "data"]
    )

    static let documentation = WorkflowTemplate(
        id: "documentation",
        name: "Documentation",
        description: "Generate or update project documentation",
        icon: "doc.text.fill",
        branchType: .conversation,
        suggestedModel: nil,
        initialPrompt: nil,
        systemContext: """
            Documentation standards:
            - Clear, concise language
            - Code examples where helpful
            - Architecture decisions documented with rationale
            - API docs with parameter descriptions
            """,
        sandboxProfile: "unrestricted",
        reviewMode: .none,
        recommendedAgentIds: ["kim", "uhura"]
    )

    static let debugging = WorkflowTemplate(
        id: "debugging",
        name: "Debug Session",
        description: "Systematic debugging with logging and profiling",
        icon: "ant.fill",
        branchType: .implementation,
        suggestedModel: nil,
        initialPrompt: nil,
        systemContext: """
            Debugging protocol:
            1. Describe the symptom clearly
            2. Check logs and error messages
            3. Reproduce with minimal steps
            4. Form hypothesis
            5. Test hypothesis
            6. Fix and verify
            """,
        sandboxProfile: "workspace",
        reviewMode: .none,
        recommendedAgentIds: ["geordi", "worf"]
    )
}
