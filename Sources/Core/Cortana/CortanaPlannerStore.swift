import Foundation
import SwiftUI

enum CortanaPlannerRole: String, Codable {
    case user
    case cortana
}

struct CortanaPlanningMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: CortanaPlannerRole
    let content: String
    let createdAt: Date

    init(id: UUID = UUID(), role: CortanaPlannerRole, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

enum CortanaPromotionTarget: String, Codable, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var label: String {
        switch self {
        case .codex: return "Promote to Codex"
        case .claude: return "Promote to Claude"
        }
    }

    var modelId: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude-sonnet-4-6"
        }
    }

    var laneDescription: String {
        switch self {
        case .codex: return "repo-driving implementation lane"
        case .claude: return "reasoning and architecture lane"
        }
    }

    var promptHeadline: String {
        switch self {
        case .codex: return "Built for direct repo work"
        case .claude: return "Built for strategy and hard reasoning"
        }
    }

    var promptGuidance: String {
        switch self {
        case .codex:
            return "Use when you want the model to inspect the codebase, make changes, verify them, and report concrete blockers without drifting into a long planning monologue."
        case .claude:
            return "Use when the problem needs architectural judgment, tradeoff analysis, or a sharper execution plan before code changes start."
        }
    }
}

struct CortanaBrief: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var summary: String
    var projectName: String
    var workingDirectory: String?
    var recommendedModelId: String
    var routeReason: String
    var goals: [String]
    var constraints: [String]
    var sourceMessageId: UUID
    var createdAt: Date
    var promotedTarget: CortanaPromotionTarget?
    var promotedTreeId: String?
    var promotedBranchId: String?

    init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        projectName: String,
        workingDirectory: String?,
        recommendedModelId: String,
        routeReason: String,
        goals: [String],
        constraints: [String],
        sourceMessageId: UUID,
        createdAt: Date = Date(),
        promotedTarget: CortanaPromotionTarget? = nil,
        promotedTreeId: String? = nil,
        promotedBranchId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        self.recommendedModelId = recommendedModelId
        self.routeReason = routeReason
        self.goals = goals
        self.constraints = constraints
        self.sourceMessageId = sourceMessageId
        self.createdAt = createdAt
        self.promotedTarget = promotedTarget
        self.promotedTreeId = promotedTreeId
        self.promotedBranchId = promotedBranchId
    }

    func executionPrompt(for target: CortanaPromotionTarget) -> String {
        let goalsText = goals.map { "- \($0)" }.joined(separator: "\n")
        let constraintsText = constraints.isEmpty
            ? "- Preserve established project patterns and keep the work scoped."
            : constraints.map { "- \($0)" }.joined(separator: "\n")
        let workingDirectoryLine = workingDirectory.map { "Working directory: \($0)" } ?? "Working directory: not specified"

        switch target {
        case .codex:
            return """
            Cortana execution brief for Codex

            Mission:
            Drive the next implementation slice directly in the repo.

            Project: \(projectName)
            Title: \(title)
            Summary: \(summary)
            \(workingDirectoryLine)

            Goals:
            \(goalsText)

            Constraints:
            \(constraintsText)

            Operating rules:
            - Inspect the existing code before changing it.
            - Prefer small coherent edits over broad refactors.
            - Implement the requested slice end to end instead of stopping at analysis.
            - Run the narrowest meaningful verification for touched areas.
            - Report concrete blockers or risks, not generic caveats.

            Deliverable:
            1. Make the code or project changes.
            2. Verify with build/test checks when possible.
            3. Summarize what changed, what was verified, and what still needs attention.
            """

        case .claude:
            return """
            Cortana execution brief for Claude

            Mission:
            Sharpen the approach where strategy, architecture, or prompt design matters before execution moves forward.

            Project: \(projectName)
            Title: \(title)
            Summary: \(summary)
            \(workingDirectoryLine)

            Goals:
            \(goalsText)

            Constraints:
            \(constraintsText)

            Operating rules:
            - Start by clarifying the problem shape, risks, and tradeoffs.
            - Challenge weak assumptions and tighten the plan before expanding scope.
            - If implementation is appropriate, keep it aligned to the recommended approach.
            - Prefer crisp reasoning, decision-quality guidance, and targeted changes over broad churn.
            - Call out where Codex would be the better follow-on lane for direct repo execution.

            Deliverable:
            1. Present the strongest approach with the key tradeoffs.
            2. Refine the execution plan or prompt so another model can run it cleanly if needed.
            3. If changes are made, summarize them and identify residual risk.
            """
        }
    }

    func systemContext() -> String {
        let goalsText = goals.map { "- \($0)" }.joined(separator: "\n")
        let constraintsText = constraints.isEmpty
            ? "- Preserve project continuity."
            : constraints.map { "- \($0)" }.joined(separator: "\n")

        return """
        Cortana planning brief

        Title: \(title)
        Project: \(projectName)
        Summary: \(summary)

        Goals:
        \(goalsText)

        Constraints:
        \(constraintsText)

        Recommended lane: \(ModelCatalog.label(for: recommendedModelId))
        Reason: \(routeReason)
        """
    }
}

private struct CortanaPlannerState: Codable {
    var messages: [CortanaPlanningMessage]
    var briefs: [CortanaBrief]
}

@MainActor
final class CortanaPlannerStore: ObservableObject {
    static let shared = CortanaPlannerStore()

    @Published private(set) var messages: [CortanaPlanningMessage] = []
    @Published private(set) var briefs: [CortanaBrief] = []
    @Published var currentDraft: String = ""
    @Published var errorMessage: String?

    private let stateURL: URL
    private let fallbackWorkingDirectory = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Development"

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = appSupport.appendingPathComponent("WorldTree", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateURL = directory.appendingPathComponent("cortana-planner.json")
        load()
        if messages.isEmpty {
            messages = [
                CortanaPlanningMessage(
                    role: .cortana,
                    content: "This lane is for planning first. Bring me the idea, the mess, or the half-formed request. I’ll turn it into a project brief and a clean promotion into Codex or Claude."
                )
            ]
            save()
        }
    }

    var latestBrief: CortanaBrief? {
        briefs.sorted(by: { $0.createdAt > $1.createdAt }).first
    }

    func sendCurrentDraft() {
        let trimmed = currentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentDraft = ""
        send(trimmed)
    }

    func send(_ text: String) {
        let userMessage = CortanaPlanningMessage(role: .user, content: text)
        messages.append(userMessage)

        let brief = draftBrief(from: text, sourceMessageId: userMessage.id)
        briefs.removeAll { $0.id == brief.id }
        briefs.insert(brief, at: 0)

        let assistant = CortanaPlanningMessage(
            role: .cortana,
            content: planningResponse(for: brief)
        )
        messages.append(assistant)
        save()

        guard DaemonService.shared.isConnected else { return }
        Task {
            await requestLocalFollowUp(for: text, brief: brief)
        }
    }

    func promoteLatestBrief(to target: CortanaPromotionTarget) {
        guard let brief = latestBrief else { return }
        _ = promote(briefID: brief.id, to: target)
    }

    @discardableResult
    func promote(briefID: UUID, to target: CortanaPromotionTarget) -> CortanaBrief? {
        guard let index = briefs.firstIndex(where: { $0.id == briefID }) else { return nil }
        guard let promoted = promote(brief: briefs[index], to: target) else { return nil }
        briefs[index] = promoted
        save()
        return promoted
    }

    @discardableResult
    func promote(brief: CortanaBrief, to target: CortanaPromotionTarget) -> CortanaBrief? {
        var brief = brief
        do {
            let tree = try TreeStore.shared.createTree(
                name: brief.title,
                project: brief.projectName,
                workingDirectory: brief.workingDirectory
            )
            let branch = try TreeStore.shared.createBranch(
                treeId: tree.id,
                title: "Main",
                contextSnapshot: brief.systemContext(),
                workingDirectory: brief.workingDirectory
            )

            if let sessionId = branch.sessionId {
                UserDefaults.standard.set(brief.executionPrompt(for: target), forKey: "pending_synthesis_\(sessionId)")
                UserDefaults.standard.set(target.modelId, forKey: "pending_model_override_\(sessionId)")
            }

            brief.promotedTarget = target
            brief.promotedTreeId = tree.id
            brief.promotedBranchId = branch.id

            AppState.shared.sidebarDestination = .conversations
            AppState.shared.selectBranch(branch.id, in: tree.id)
            AppState.shared.terminalVisible = true

            messages.append(
                CortanaPlanningMessage(
                    role: .cortana,
                    content: "I promoted `\(brief.title)` into `\(target.label.replacingOccurrences(of: "Promote to ", with: ""))` and opened a new tree under `\(brief.projectName)`. The first execution brief is queued."
                )
            )
            errorMessage = nil
            save()
            return brief
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func draftBrief(
        from text: String,
        sourceMessageId: UUID = UUID(),
        projectNameOverride: String? = nil,
        workingDirectoryOverride: String? = nil
    ) -> CortanaBrief {
        let route = ProviderManager.shared.routePreview(message: text)
        let projects = (try? TreeStore.shared.getTrees(includeArchived: false)) ?? []
        let projectNames = Array(Set(projects.compactMap(\.project))).sorted()
        let projectName = projectNameOverride ?? inferProjectName(from: text, existingProjects: projectNames)
        let workingDirectory = workingDirectoryOverride ?? inferWorkingDirectory(for: projectName, from: projects)
        let title = inferTitle(from: text, projectName: projectName)
        let summary = summarize(text)
        let constraints = inferConstraints(from: text)

        return CortanaBrief(
            title: title,
            summary: summary,
            projectName: projectName,
            workingDirectory: workingDirectory,
            recommendedModelId: route.primaryModelId,
            routeReason: route.reason,
            goals: inferGoals(from: text, summary: summary),
            constraints: constraints,
            sourceMessageId: sourceMessageId
        )
    }

    func planningResponse(for brief: CortanaBrief) -> String {
        let lane = ModelCatalog.label(for: brief.recommendedModelId)
        let goals = brief.goals.prefix(3).map { "• \($0)" }.joined(separator: "\n")
        let constraints = brief.constraints.prefix(2).map { "• \($0)" }.joined(separator: "\n")
        let constraintBlock = constraints.isEmpty ? "" : "\nConstraints:\n\(constraints)"

        return """
        I turned that into a concrete brief for `\(brief.projectName)`.

        \(brief.summary)

        Next lane: \(lane)
        Reason: \(brief.routeReason)

        Goals:
        \(goals)\(constraintBlock)
        """
    }

    private func inferProjectName(from text: String, existingProjects: [String]) -> String {
        let lower = text.lowercased()
        if let existing = existingProjects.first(where: { lower.contains($0.lowercased()) }) {
            return existing
        }

        if let quoted = firstQuotedPhrase(in: text) {
            return normalizeProjectName(quoted)
        }

        let words = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .map(String.init)
        let filtered = words.filter { word in
            let lowerWord = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return !["make", "build", "create", "start", "plan", "new", "project", "app", "for", "the", "a", "an"].contains(lowerWord)
        }
        guard let first = filtered.first else { return AppConstants.defaultProjectName }
        return normalizeProjectName(first)
    }

    private func inferWorkingDirectory(for projectName: String, from trees: [ConversationTree]) -> String? {
        if let directory = trees.first(where: { ($0.project ?? AppConstants.defaultProjectName) == projectName })?.workingDirectory,
           !directory.isEmpty {
            return directory
        }
        if projectName == AppConstants.defaultProjectName {
            return fallbackWorkingDirectory
        }
        return "\(fallbackWorkingDirectory)/\(projectName)"
    }

    private func inferTitle(from text: String, projectName: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        let words = firstLine.split(separator: " ").prefix(7).joined(separator: " ")
        let cleaned = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return "\(projectName) Plan"
        }
        let title = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        return title.count > 72 ? String(title.prefix(72)) : title
    }

    private func summarize(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count <= 180 {
            return normalized
        }
        return String(normalized.prefix(177)) + "..."
    }

    private func inferGoals(from text: String, summary: String) -> [String] {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let extracted = lines
            .filter { $0.hasPrefix("-") || $0.hasPrefix("*") || $0.first?.isNumber == true }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*0123456789. ").union(.whitespaces)) }
        if !extracted.isEmpty {
            return Array(extracted.prefix(4))
        }
        return [summary]
    }

    private func inferConstraints(from text: String) -> [String] {
        var constraints: [String] = []
        let lower = text.lowercased()
        if lower.contains("local") {
            constraints.append("Keep the primary planning and orchestration loop local.")
        }
        if lower.contains("production") || lower.contains("solid") {
            constraints.append("Treat this as production-grade work, not a prototype.")
        }
        if lower.contains("world tree") {
            constraints.append("Preserve World Tree as the operator surface and terminal viewport.")
        }
        if lower.contains("codex") || lower.contains("claude") {
            constraints.append("Only escalate to Codex or Claude once the brief is explicit.")
        }
        return constraints
    }

    private func normalizeProjectName(_ value: String) -> String {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        guard !cleaned.isEmpty else { return AppConstants.defaultProjectName }
        let words = cleaned
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .prefix(3)
            .map { token -> String in
                let lower = token.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
        return words.joined()
    }

    private func firstQuotedPhrase(in text: String) -> String? {
        guard let first = text.firstIndex(of: "\""),
              let second = text[text.index(after: first)...].firstIndex(of: "\""),
              first < second else {
            return nil
        }
        return String(text[text.index(after: first)..<second])
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let decoded = try? JSONDecoder().decode(CortanaPlannerState.self, from: data) else {
            return
        }
        messages = decoded.messages
        briefs = decoded.briefs
    }

    private func requestLocalFollowUp(for text: String, brief: CortanaBrief) async {
        var response = ""
        let stream = await DaemonChannel.shared.send(
            text: """
            Help me refine this planning brief before I promote it to an execution lane.

            User request:
            \(text)

            Current brief:
            \(brief.systemContext())
            """,
            project: brief.projectName,
            branchId: nil,
            sessionId: "cortana-planner"
        )

        for await event in stream {
            switch event {
            case .text(let token):
                response += token
            case .done:
                let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                messages.append(CortanaPlanningMessage(role: .cortana, content: trimmed))
                save()
                return
            case .error(let message):
                errorMessage = message
                return
            default:
                continue
            }
        }
    }

    private func save() {
        let state = CortanaPlannerState(messages: messages, briefs: briefs)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}
