import Foundation

struct ProjectPlanningDocument: Codable, Equatable {
    var projectName: String
    var workingDirectory: String?
    var overview: String
    var desiredOutcome: String
    var planOutline: String
    var decisionLog: String
    var promptNotes: String
    var cortanaNotes: String
    var latestBrief: CortanaBrief?
    var updatedAt: Date

    init(
        projectName: String,
        workingDirectory: String?,
        overview: String = "",
        desiredOutcome: String = "",
        planOutline: String = "",
        decisionLog: String = "",
        promptNotes: String = "",
        cortanaNotes: String = "",
        latestBrief: CortanaBrief? = nil,
        updatedAt: Date = Date()
    ) {
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        self.overview = overview
        self.desiredOutcome = desiredOutcome
        self.planOutline = planOutline
        self.decisionLog = decisionLog
        self.promptNotes = promptNotes
        self.cortanaNotes = cortanaNotes
        self.latestBrief = latestBrief
        self.updatedAt = updatedAt
    }
}

private struct ProjectDocsState: Codable {
    var documents: [String: ProjectPlanningDocument]
}

@MainActor
final class ProjectDocsStore: ObservableObject {
    static let shared = ProjectDocsStore()

    @Published private(set) var documents: [String: ProjectPlanningDocument] = [:]
    @Published var errorMessage: String?
    @Published var isRefining = false

    private let stateURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = appSupport
            .appendingPathComponent("WorldTree", isDirectory: true)
            .appendingPathComponent("project-docs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateURL = directory.appendingPathComponent("project-plans.json")
        load()
        bootstrapCachedProjects()
    }

    func document(for projectName: String, workingDirectory: String?) -> ProjectPlanningDocument {
        let key = normalizedKey(for: projectName)
        if var existing = documents[key] {
            var shouldSave = false
            if existing.workingDirectory == nil || existing.workingDirectory?.isEmpty == true {
                existing.workingDirectory = workingDirectory
                shouldSave = true
            }
            if existing.isSubstantiallyEmpty {
                existing = makeSeededDocument(projectName: projectName, workingDirectory: workingDirectory)
                shouldSave = true
            }
            if shouldSave {
                documents[key] = existing
                save()
            }
            return existing
        }

        let document = makeSeededDocument(projectName: projectName, workingDirectory: workingDirectory)
        documents[key] = document
        save()
        return document
    }

    func save(document: ProjectPlanningDocument) {
        var updated = document
        updated.updatedAt = Date()
        documents[normalizedKey(for: document.projectName)] = updated
        errorMessage = nil
        save()
    }

    func draftBrief(for projectName: String, workingDirectory: String?) -> CortanaBrief {
        let document = document(for: projectName, workingDirectory: workingDirectory)
        let source = compiledPromptSource(for: document)
        let brief = CortanaPlannerStore.shared.draftBrief(
            from: source,
            projectNameOverride: projectName,
            workingDirectoryOverride: workingDirectory
        )

        var updated = document
        updated.latestBrief = brief
        save(document: updated)
        return brief
    }

    func promoteLatestBrief(for projectName: String, to target: CortanaPromotionTarget) {
        let key = normalizedKey(for: projectName)
        guard let document = documents[key],
              let brief = document.latestBrief,
              let promoted = CortanaPlannerStore.shared.promote(brief: brief, to: target) else {
            return
        }

        var updated = document
        updated.latestBrief = promoted
        save(document: updated)
    }

    func compiledPromptSource(for document: ProjectPlanningDocument) -> String {
        let sections: [(String, String)] = [
            ("Project", document.projectName),
            ("Working Directory", document.workingDirectory ?? ""),
            ("Overview", document.overview),
            ("Desired Outcome", document.desiredOutcome),
            ("Plan Outline", document.planOutline),
            ("Decisions and Constraints", document.decisionLog),
            ("Prompt Notes", document.promptNotes),
            ("Cortana Notes", document.cortanaNotes)
        ]

        return sections
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.0):\n\($0.1.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
    }

    func referenceSnapshot(for projectName: String, workingDirectory: String?) -> ProjectDocsReferenceSnapshot {
        let source = makeSeedSource(projectName: projectName, workingDirectory: workingDirectory)
        return ProjectDocsReferenceSnapshot(
            projectType: source.projectType,
            gitBranch: source.gitBranch,
            isDirty: source.isDirty,
            sourceTitles: source.documentExcerpts.map(\.title),
            headings: Array(uniquePreservingOrder(source.documentExcerpts.flatMap(\.headings)).prefix(8)),
            signals: source.conversationSignals
        )
    }

    func refineWithCortana(projectName: String, workingDirectory: String?) async {
        guard DaemonService.shared.isConnected else {
            errorMessage = "Local Cortana daemon is not connected."
            return
        }

        let document = document(for: projectName, workingDirectory: workingDirectory)
        let source = compiledPromptSource(for: document)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Add some project context before asking Cortana to tighten the brief."
            return
        }

        isRefining = true
        defer { isRefining = false }

        var response = ""
        let stream = await DaemonChannel.shared.send(
            text: """
            Tighten this project planning brief for execution. Return concise markdown with:
            1. A sharper summary
            2. Missing constraints or open questions
            3. A clean execution prompt suitable for Codex or Claude

            \(source)
            """,
            project: projectName,
            branchId: nil,
            sessionId: "project-docs-\(normalizedKey(for: projectName))"
        )

        for await event in stream {
            switch event {
            case .text(let token):
                response += token
            case .done:
                let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                var updated = document
                updated.cortanaNotes = trimmed
                save(document: updated)
                errorMessage = nil
                return
            case .error(let message):
                errorMessage = message
                return
            default:
                continue
            }
        }
    }

    private func normalizedKey(for projectName: String) -> String {
        projectName.lowercased()
    }

    private func makeSeededDocument(projectName: String, workingDirectory: String?) -> ProjectPlanningDocument {
        let source = makeSeedSource(projectName: projectName, workingDirectory: workingDirectory)
        return ProjectDocsSeeder.seededDocument(from: source)
    }

    private func makeSeedSource(projectName: String, workingDirectory: String?) -> ProjectDocsSeedSource {
        let cachedProject: CachedProject?
        if let workingDirectory, let project = try? ProjectCache().get(path: workingDirectory) {
            cachedProject = project
        } else {
            cachedProject = try? ProjectCache().getByName(projectName)
        }

        let source = ProjectDocsSeeder.makeSeedSource(
            projectName: projectName,
            workingDirectory: workingDirectory,
            cachedProject: cachedProject
        )
        return source
    }

    private func bootstrapCachedProjects() {
        guard let projects = try? ProjectCache().getAll(), !projects.isEmpty else {
            return
        }

        var didChange = false
        for project in projects {
            let key = normalizedKey(for: project.name)
            guard documents[key] == nil else { continue }
            documents[key] = makeSeededDocument(projectName: project.name, workingDirectory: project.path)
            didChange = true
        }

        if didChange {
            save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let decoded = try? JSONDecoder().decode(ProjectDocsState.self, from: data) else {
            return
        }
        documents = decoded.documents
    }

    private func save() {
        let state = ProjectDocsState(documents: documents)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}

private func uniquePreservingOrder<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
}

private extension ProjectPlanningDocument {
    var isSubstantiallyEmpty: Bool {
        overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && desiredOutcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && planOutline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && decisionLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && promptNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && cortanaNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && latestBrief == nil
    }
}

struct ProjectDocExcerpt: Equatable {
    let title: String
    let summary: String
    let headings: [String]
    let bullets: [String]
}

struct ProjectDocsReferenceSnapshot: Equatable {
    let projectType: ProjectType?
    let gitBranch: String?
    let isDirty: Bool
    let sourceTitles: [String]
    let headings: [String]
    let signals: [String]

    static let empty = ProjectDocsReferenceSnapshot(
        projectType: nil,
        gitBranch: nil,
        isDirty: false,
        sourceTitles: [],
        headings: [],
        signals: []
    )
}

struct ProjectDocsSeedSource {
    let projectName: String
    let workingDirectory: String?
    let projectType: ProjectType?
    let gitBranch: String?
    let isDirty: Bool
    let readme: String?
    let documentExcerpts: [ProjectDocExcerpt]
    let conversationSignals: [String]
}

enum ProjectDocsSeeder {
    static func makeSeedSource(
        projectName: String,
        workingDirectory: String?,
        cachedProject: CachedProject?
    ) -> ProjectDocsSeedSource {
        let directory = workingDirectory ?? cachedProject?.path
        let readme = cachedProject?.readme ?? loadREADME(from: directory)
        return ProjectDocsSeedSource(
            projectName: projectName,
            workingDirectory: directory,
            projectType: cachedProject?.type,
            gitBranch: cachedProject?.gitBranch,
            isDirty: cachedProject?.gitDirty ?? false,
            readme: readme,
            documentExcerpts: loadDocumentExcerpts(from: directory),
            conversationSignals: curatedSignals(for: projectName)
        )
    }

    static func seededDocument(from source: ProjectDocsSeedSource, now: Date = Date()) -> ProjectPlanningDocument {
        let overview = composeOverview(from: source)
        let desiredOutcome = composeDesiredOutcome(from: source)
        let planOutline = composePlanOutline(from: source)
        let decisionLog = composeDecisionLog(from: source)
        let promptNotes = composePromptNotes(from: source)
        let cortanaNotes = composeCortanaNotes(from: source)

        return ProjectPlanningDocument(
            projectName: source.projectName,
            workingDirectory: source.workingDirectory,
            overview: overview,
            desiredOutcome: desiredOutcome,
            planOutline: planOutline,
            decisionLog: decisionLog,
            promptNotes: promptNotes,
            cortanaNotes: cortanaNotes,
            latestBrief: nil,
            updatedAt: now
        )
    }

    private static func composeOverview(from source: ProjectDocsSeedSource) -> String {
        let summary = [
            readmeSummary(from: source.readme),
            source.documentExcerpts.lazy.map(\.summary).first(where: { !$0.isEmpty }),
            defaultOverview(for: source)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty }) ?? defaultOverview(for: source)

        var lines: [String] = [summary]

        if let branch = source.gitBranch, !branch.isEmpty {
            let dirtySuffix = source.isDirty ? " with uncommitted changes" : ""
            lines.append("Current branch: \(branch)\(dirtySuffix).")
        }

        let docTitles = source.documentExcerpts.prefix(4).map(\.title)
        if !docTitles.isEmpty {
            lines.append("Primary source material: \(joinedList(docTitles)).")
        }

        if !source.conversationSignals.isEmpty {
            lines.append("Recent planning direction: \(source.conversationSignals.prefix(2).joined(separator: " "))")
        }

        return lines.joined(separator: "\n\n")
    }

    private static func composeDesiredOutcome(from source: ProjectDocsSeedSource) -> String {
        let items = uniquePreservingOrder(worldTreeDesiredOutcome(for: source.projectName) + fallbackBullets(from: source, limit: 6))
        let resolved = items.isEmpty ? defaultDesiredOutcome(for: source) : items.prefix(6).map { "- \($0)" }
        return resolved.joined(separator: "\n")
    }

    private static func composePlanOutline(from source: ProjectDocsSeedSource) -> String {
        let worldTreePlan = worldTreePlanOutline(for: source.projectName)
        if !worldTreePlan.isEmpty {
            return worldTreePlan.enumerated().map { "\(String($0.offset + 1)). \($0.element)" }.joined(separator: "\n")
        }

        var phases = fallbackHeadings(from: source, limit: 4)
        if phases.isEmpty {
            phases = [
                "Consolidate the current source material into a single working plan.",
                "Turn the plan into an execution sequence with explicit milestones.",
                "Draft model-specific prompts before handing implementation to the execution lane.",
                "Verify the resulting slice and capture the decision trail here."
            ]
        }

        return phases.enumerated().map { "\(String($0.offset + 1)). \($0.element)" }.joined(separator: "\n")
    }

    private static func composeDecisionLog(from source: ProjectDocsSeedSource) -> String {
        let items = uniquePreservingOrder(worldTreeDecisions(for: source.projectName) + fallbackBullets(from: source, limit: 8))
        let resolved = items.isEmpty ? defaultDecisions(for: source) : items.prefix(8).map { "- \($0)" }
        return resolved.joined(separator: "\n")
    }

    private static func composePromptNotes(from source: ProjectDocsSeedSource) -> String {
        var notes = [
            "- Start every prompt with the exact outcome, project, and working directory.",
            "- Name constraints and non-goals before asking for changes.",
            "- Require the narrowest meaningful verification path for any touched surface.",
            "- Ask Claude for strategy, tradeoffs, or architecture when the shape is still unclear.",
            "- Ask Codex for direct repo inspection, implementation, and concrete blocker reporting when the plan is already sharp."
        ]

        if source.projectName.caseInsensitiveCompare("WorldTree") == .orderedSame {
            notes.append("- For World Tree, keep provider routing, conversation state, and MCP/plugin integration in the risk frame.")
            notes.append("- Prompt Claude to refine the plan when the problem smells architectural; prompt Codex when the next step is a bounded Swift or SwiftUI implementation slice.")
        }

        return notes.joined(separator: "\n")
    }

    private static func composeCortanaNotes(from source: ProjectDocsSeedSource) -> String {
        let signals = source.conversationSignals
        if !signals.isEmpty {
            return signals.prefix(6).map { "- \($0)" }.joined(separator: "\n")
        }

        return [
            "- Use this space as the durable project notebook, not a disposable scratchpad.",
            "- Capture why decisions were made, not just what changed.",
            "- Refresh the brief before handing work off to the execution lane."
        ].joined(separator: "\n")
    }

    private static func fallbackBullets(from source: ProjectDocsSeedSource, limit: Int) -> [String] {
        uniquePreservingOrder(source.documentExcerpts.flatMap(\.bullets)).prefix(limit).map { $0 }
    }

    private static func fallbackHeadings(from source: ProjectDocsSeedSource, limit: Int) -> [String] {
        uniquePreservingOrder(source.documentExcerpts.flatMap(\.headings)).prefix(limit).map { heading in
            heading.hasSuffix(".") ? heading : "\(heading)."
        }
    }

    private static func defaultOverview(for source: ProjectDocsSeedSource) -> String {
        if let type = source.projectType?.displayName {
            return "\(source.projectName) is an active \(type) project with planning material ready to consolidate into one working brief."
        }
        return "\(source.projectName) is an active project that needs a clear working brief tied to the code and docs already on disk."
    }

    private static func defaultDesiredOutcome(for source: ProjectDocsSeedSource) -> [String] {
        [
            "- Clarify the product direction and define what done looks like.",
            "- Turn scattered notes into a stable execution plan for \(source.projectName).",
            "- Keep a durable record of decisions, constraints, and prompt strategy."
        ]
    }

    private static func defaultDecisions(for source: ProjectDocsSeedSource) -> [String] {
        [
            "- Treat this document as the canonical planning surface for \(source.projectName).",
            "- Preserve project-native patterns rather than introducing style churn while planning.",
            "- Record constraints and tradeoffs here before handing work to a model."
        ]
    }

    private static func readmeSummary(from readme: String?) -> String? {
        guard let readme else { return nil }
        return summarizeMarkdown(readme, characterLimit: 320)
    }

    private static func loadREADME(from directory: String?) -> String? {
        guard let directory else { return nil }
        let path = URL(fileURLWithPath: directory).appendingPathComponent("README.md").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private static func loadDocumentExcerpts(from directory: String?) -> [ProjectDocExcerpt] {
        guard let directory else { return [] }
        let rootURL = URL(fileURLWithPath: directory)
        let paths = candidateDocumentationURLs(rootURL: rootURL)

        return paths.compactMap { url in
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let summary = summarizeMarkdown(content, characterLimit: 280)
            let headings = extractHeadings(from: content, limit: 4)
            let bullets = extractBullets(from: content, limit: 6)
            guard !summary.isEmpty || !headings.isEmpty || !bullets.isEmpty else { return nil }
            return ProjectDocExcerpt(
                title: prettifyTitle(url.deletingPathExtension().lastPathComponent),
                summary: summary,
                headings: headings,
                bullets: bullets
            )
        }
    }

    private static func candidateDocumentationURLs(rootURL: URL) -> [URL] {
        let fileManager = FileManager.default
        let priorityRelativePaths = [
            "README.md",
            "MISSION.md",
            "ARCHITECTURE.md",
            "PLAYBOOK.md",
            "BUILD.md",
            "CLAUDE.md",
            "AGENTS.md",
            ".claude/BRAIN.md",
            ".claude/OPTIMIZATION-PLAN.md",
            ".claude/VISION_IMPLEMENTATION_PLAN.md",
            ".claude/PHASE1_PROGRESS.md",
            ".claude/PHASE1_COMPLETE.md",
            ".claude/verification.md",
            "docs/CANVAS-VISION.md",
            "docs/STRESS-TEST-PLAN.md",
            "docs/CORTANA-DAEMON-ARCHITECTURE.md"
        ]

        var urls: [URL] = priorityRelativePaths
            .map { rootURL.appendingPathComponent($0) }
            .filter { fileManager.fileExists(atPath: $0.path) }

        let extraRoots = [
            rootURL.appendingPathComponent("docs", isDirectory: true),
            rootURL.appendingPathComponent(".claude/epic", isDirectory: true)
        ]

        for extraRoot in extraRoots where fileManager.fileExists(atPath: extraRoot.path) {
            let enumerator = fileManager.enumerator(
                at: extraRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "md" else { continue }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else {
                    continue
                }
                urls.append(url)
                if urls.count >= 12 {
                    break
                }
            }
        }

        return uniquePreservingOrder(urls).prefix(12).map { $0 }
    }

    private static func summarizeMarkdown(_ text: String, characterLimit: Int) -> String {
        var inCodeBlock = false
        var collected: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock || line.isEmpty || line.hasPrefix("#") || isBulletLine(line) {
                continue
            }
            collected.append(cleanMarkdownLine(line))
            let candidate = collected.joined(separator: " ")
            if candidate.count >= characterLimit {
                return String(candidate.prefix(characterLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if collected.count >= 3 {
                break
            }
        }

        return collected.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractHeadings(from text: String, limit: Int) -> [String] {
        var headings: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#") else { continue }
            let heading = cleanMarkdownLine(line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
            guard !heading.isEmpty else { continue }
            headings.append(heading)
            if headings.count == limit {
                break
            }
        }

        return uniquePreservingOrder(headings)
    }

    private static func extractBullets(from text: String, limit: Int) -> [String] {
        var bullets: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isBulletLine(line) else { continue }
            let bullet = cleanMarkdownLine(strippedBulletPrefix(from: line))
            guard !bullet.isEmpty else { continue }
            bullets.append(bullet)
            if bullets.count == limit {
                break
            }
        }

        return uniquePreservingOrder(bullets)
    }

    private static func isBulletLine(_ line: String) -> Bool {
        line.hasPrefix("- ")
            || line.hasPrefix("* ")
            || line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
    }

    private static func strippedBulletPrefix(from line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return String(line.dropFirst(2))
        }

        if let range = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            return String(line[range.upperBound...])
        }

        return line
    }

    private static func cleanMarkdownLine(_ line: String) -> String {
        line
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\[(.*?)\]\((.*?)\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func prettifyTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private static func joinedList(_ values: [String]) -> String {
        switch values.count {
        case 0:
            return ""
        case 1:
            return values[0]
        case 2:
            return "\(values[0]) and \(values[1])"
        default:
            return values.dropLast().joined(separator: ", ") + ", and " + (values.last ?? "")
        }
    }

    private static func curatedSignals(for projectName: String) -> [String] {
        switch projectName.lowercased() {
        case "worldtree", "world tree":
            return [
                "Docs should live under each project in the project control tree, not inside a separate Cortana-only tab.",
                "Use this notebook as the canonical place for product vision, architecture decisions, constraints, prompt patterns, and active plans.",
                "Shape prompts differently for Claude and Codex instead of pretending one brief fits both lanes.",
                "Claude should get the strategy, tradeoffs, and prompt refinement lane; Codex should get the direct repo execution lane.",
                "The Command Center and project docs together should replace the old Cortana tab rather than duplicating it.",
                "Prepopulate the docs from current repo material and recent working conversation so the notebook starts with real context."
            ]
        default:
            return []
        }
    }

    private static func worldTreeDesiredOutcome(for projectName: String) -> [String] {
        guard projectName.caseInsensitiveCompare("WorldTree") == .orderedSame
            || projectName.caseInsensitiveCompare("World Tree") == .orderedSame else {
            return []
        }

        return [
            "Make per-project docs the durable planning surface for vision, constraints, and prompt design.",
            "Retire the dedicated Cortana planning tab by folding its useful behavior into Docs plus Command Center.",
            "Generate execution prompts that deliberately fit Claude's reasoning lane and Codex's repo-driving lane.",
            "Keep World Tree local-first while hardening conversation recovery, provider routing, and multi-window reliability."
        ]
    }

    private static func worldTreePlanOutline(for projectName: String) -> [String] {
        guard projectName.caseInsensitiveCompare("WorldTree") == .orderedSame
            || projectName.caseInsensitiveCompare("World Tree") == .orderedSame else {
            return []
        }

        return [
            "Expose Docs as a hidden child under each project and make it feel like the notebook attached to the work, not a detached planning toy.",
            "Seed every project doc from repo markdown and cached project context so the first open has real material to refine.",
            "Use the execution lane to compile model-specific briefs, with Claude for reasoning-heavy shaping and Codex for bounded implementation.",
            "Verify the resulting flow with a targeted rebuild and QA pass, especially around provider behavior, conversation state, and window switching."
        ]
    }

    private static func worldTreeDecisions(for projectName: String) -> [String] {
        guard projectName.caseInsensitiveCompare("WorldTree") == .orderedSame
            || projectName.caseInsensitiveCompare("World Tree") == .orderedSame else {
            return []
        }

        return [
            "Favor Starfleet terminology in user-facing orchestration instead of older Pantheon language.",
            "Treat provider support, conversation state, and MCP/plugin integration as high-risk surfaces whenever the command/docs flow changes.",
            "Keep docs embedded in the project tree so planning stays attached to the code and project context.",
            "Do not build an Obsidian clone here; build a focused project notebook that improves execution.",
            "Model-specific prompt shaping is required because Claude and Codex respond best to different instructions."
        ]
    }
}
