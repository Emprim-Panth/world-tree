import Foundation

// MARK: - Workflow Templates

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

    // MARK: - Built-in Templates

    static let all: [WorkflowTemplate] = [
        bugFix, featureImpl, codeReview, refactor, exploration, documentation, debugging
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
        sandboxProfile: "workspace"
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
        sandboxProfile: "workspace"
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
        sandboxProfile: "unrestricted"
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
        sandboxProfile: "workspace"
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
        sandboxProfile: "unrestricted"
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
        sandboxProfile: "unrestricted"
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
        sandboxProfile: "workspace"
    )
}
