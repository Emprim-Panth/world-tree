import AppKit
import SwiftUI

struct ProjectDocsView: View {
    let projectName: String
    let workingDirectory: String?

    @Environment(AppState.self) private var appState
    @StateObject private var store = ProjectDocsStore.shared
    @State private var document: ProjectPlanningDocument
    @State private var referenceSnapshot = ProjectDocsReferenceSnapshot.empty
    @State private var copiedPromptTarget: CortanaPromotionTarget?

    private let canvas = Color(red: 0.09, green: 0.10, blue: 0.11)
    private let panel = Color(red: 0.13, green: 0.14, blue: 0.15)
    private let panelRaised = Color(red: 0.16, green: 0.17, blue: 0.18)
    private let panelSoft = Color(red: 0.18, green: 0.19, blue: 0.20)
    private let panelStroke = Color.white.opacity(0.08)
    private let textPrimary = Color(red: 0.92, green: 0.92, blue: 0.90)
    private let textSecondary = Color(red: 0.63, green: 0.64, blue: 0.66)
    private let accent = Color(red: 0.78, green: 0.76, blue: 0.71)
    private let accentBlue = Color(red: 0.48, green: 0.66, blue: 0.84)

    init(projectName: String, workingDirectory: String?) {
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        _document = State(initialValue: ProjectPlanningDocument(projectName: projectName, workingDirectory: workingDirectory))
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    breadcrumbBar
                    contentLayout(for: proxy.size.width)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(backgroundGradient.ignoresSafeArea())
            .task(id: projectName) {
                reloadDocument()
            }
        }
    }

    @ViewBuilder
    private func contentLayout(for width: CGFloat) -> some View {
        if width >= 1280 {
            HSplitView {
                documentColumn
                    .frame(minWidth: 720, idealWidth: width * 0.64)

                inspectorColumn
                    .frame(minWidth: 340, idealWidth: width * 0.28)
            }
            .frame(minHeight: 760)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                documentColumn
                inspectorColumn
            }
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 10) {
            Text("02 Projects")
            Text("/")
            Text(projectName)
            Text("/")
            Text("Docs")
                .foregroundStyle(textPrimary)

            Spacer()

            Button {
                appState.clearProjectSelection()
                appState.sidebarDestination = .projects
            } label: {
                Label("Projects", systemImage: "folder.fill")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(panelRaised, in: Capsule())

            Button {
                draftBrief()
            } label: {
                Label("Draft Brief", systemImage: "wand.and.stars")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(accentBlue.opacity(0.16), in: Capsule())
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(textSecondary)
    }

    private var documentColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            titleCard
            propertiesCard
            planningSections
        }
        .padding(28)
        .background(panel, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(panelStroke, lineWidth: 1)
        )
    }

    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(projectName)
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(textPrimary)

            Text("Project notebook")
                .font(.headline)
                .foregroundStyle(accent)

            Text("Docs live with the project now. Shape the plan here, refine it with Cortana, then hand a sharper brief to Claude or Codex.")
                .font(.callout)
                .foregroundStyle(textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var propertiesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Properties")
                .font(.headline)
                .foregroundStyle(textPrimary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                propertyRow("type", value: "reference", systemImage: "line.3.horizontal")
                propertyRow("project", value: projectName.lowercased(), systemImage: "folder")
                propertyRow("date", value: absoluteDateLabel, systemImage: "calendar")
                propertyRow("status", value: latestBriefStatus, systemImage: "checkmark.circle")
                propertyRow("seed", value: "docs + memory", systemImage: "sparkles")
                propertyRow("lane", value: promptLaneLabel, systemImage: "arrow.triangle.branch")
            }

            if let type = referenceSnapshot.projectType?.displayName {
                Text("Detected project type: \(type)")
                    .font(.caption)
                    .foregroundStyle(textSecondary)
            }

            if let workingDirectory, !workingDirectory.isEmpty {
                Label(workingDirectory, systemImage: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(textSecondary)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .background(panelRaised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(panelStroke, lineWidth: 1)
        )
    }

    private var planningSections: some View {
        VStack(alignment: .leading, spacing: 16) {
            documentSection(
                title: "Overview",
                subtitle: "What this project is, why it matters, and the current strategic frame.",
                text: binding(for: \.overview)
            )
            documentSection(
                title: "Desired End Result",
                subtitle: "What success looks like once this slice is actually worth shipping.",
                text: binding(for: \.desiredOutcome)
            )
            documentSection(
                title: "Plan Outline",
                subtitle: "High-level sequence, milestones, and the order of attack.",
                text: binding(for: \.planOutline),
                minHeight: 200
            )
            documentSection(
                title: "Decisions",
                subtitle: "Architecture calls, constraints, risks, and non-goals worth preserving.",
                text: binding(for: \.decisionLog),
                minHeight: 180
            )
            documentSection(
                title: "Prompt Notes",
                subtitle: "Working prompt fragments, execution context, and model-specific handoff notes.",
                text: binding(for: \.promptNotes),
                minHeight: 200
            )
        }
    }

    private var inspectorColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            executionLaneCard
            sourceMaterialCard
            cortanaNotesCard
            compiledSourceCard
        }
        .padding(22)
        .background(panel, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(panelStroke, lineWidth: 1)
        )
    }

    private var executionLaneCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Execution Lane")
                    .font(.headline)
                    .foregroundStyle(textPrimary)
                Spacer()
                if let copiedPromptTarget {
                    Text("Copied \(copiedPromptTarget == .codex ? "Codex" : "Claude")")
                        .font(.caption)
                        .foregroundStyle(textSecondary)
                }
            }

            if let error = store.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let brief = document.latestBrief {
                briefSection(brief)
            } else {
                emptyBriefState
            }
        }
        .padding(18)
        .background(panelRaised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var sourceMaterialCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Grounded Inputs")
                .font(.headline)
                .foregroundStyle(textPrimary)

            if !referenceSnapshot.sourceTitles.isEmpty {
                keyValueBlock(
                    "Source material",
                    value: referenceSnapshot.sourceTitles.prefix(6).joined(separator: "\n")
                )
            }

            if !referenceSnapshot.headings.isEmpty {
                keyValueBlock(
                    "Headings",
                    value: referenceSnapshot.headings.prefix(6).joined(separator: "\n")
                )
            }

            if let branch = referenceSnapshot.gitBranch, !branch.isEmpty {
                let dirtySuffix = referenceSnapshot.isDirty ? " • dirty" : ""
                keyValueBlock("Git", value: "\(branch)\(dirtySuffix)")
            }

            if referenceSnapshot.sourceTitles.isEmpty && referenceSnapshot.headings.isEmpty {
                Text("No repo docs found yet. The notebook can still be used, but it won’t start with much memory.")
                    .font(.callout)
                    .foregroundStyle(textSecondary)
            }
        }
        .padding(18)
        .background(panelRaised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var cortanaNotesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cortana Notes")
                .font(.headline)
                .foregroundStyle(textPrimary)

            if !document.cortanaNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                promptPanel(title: "Current read", body: document.cortanaNotes)
            } else if !referenceSnapshot.signals.isEmpty {
                promptPanel(
                    title: "Seeded direction",
                    body: referenceSnapshot.signals.prefix(5).map { "- \($0)" }.joined(separator: "\n")
                )
            } else {
                Text("Use this as the durable project notebook, not a disposable scratchpad.")
                    .font(.callout)
                    .foregroundStyle(textSecondary)
            }
        }
        .padding(18)
        .background(panelRaised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var compiledSourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compiled Source")
                .font(.headline)
                .foregroundStyle(textPrimary)

            promptPanel(
                title: "Prompt assembly",
                body: store.compiledPromptSource(for: document).ifEmpty("Start filling the document sections. This becomes the assembled context that gets turned into a brief.")
            )
        }
        .padding(18)
        .background(panelRaised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var emptyBriefState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No brief yet")
                .font(.headline)
                .foregroundStyle(textPrimary)
            Text("Draft a brief once the project plan is explicit enough to deserve an execution lane.")
                .font(.callout)
                .foregroundStyle(textSecondary)

            HStack {
                Button {
                    Task {
                        await store.refineWithCortana(projectName: projectName, workingDirectory: workingDirectory)
                        reloadDocument()
                    }
                } label: {
                    if store.isRefining {
                        Label("Refining...", systemImage: "ellipsis")
                    } else {
                        Label("Ask Cortana to Tighten", systemImage: "brain.head.profile")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.isRefining)

                Button {
                    draftBrief()
                } label: {
                    Label("Draft Execution Brief", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func briefSection(_ brief: CortanaBrief) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Latest Brief")
                .font(.headline)
                .foregroundStyle(textPrimary)

            Text(brief.title)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(textPrimary)

            Text(brief.summary)
                .font(.callout)
                .foregroundStyle(textSecondary)

            sectionList("Goals", items: brief.goals)
            if !brief.constraints.isEmpty {
                sectionList("Constraints", items: brief.constraints)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Recommended Lane")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(textSecondary)
                Text(ModelCatalog.label(for: brief.recommendedModelId))
                    .font(.callout)
                    .foregroundStyle(textPrimary)
                Text(recommendedTarget(for: brief).promptHeadline)
                    .font(.caption)
                    .foregroundStyle(textSecondary)
                Text(brief.routeReason)
                    .font(.caption)
                    .foregroundStyle(textSecondary)
            }

            ForEach(CortanaPromotionTarget.allCases) { target in
                promptVariantCard(for: target, brief: brief)
            }

            Button("Refresh with Cortana") {
                Task {
                    await store.refineWithCortana(projectName: projectName, workingDirectory: workingDirectory)
                    reloadDocument()
                    draftBrief()
                }
            }
            .buttonStyle(.bordered)
            .disabled(store.isRefining)
        }
    }

    private func promptVariantCard(for target: CortanaPromotionTarget, brief: CortanaBrief) -> some View {
        let isRecommended = target == recommendedTarget(for: brief)
        let title = target.label.replacingOccurrences(of: "Promote to ", with: "")

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(textPrimary)
                    Text(target.promptHeadline)
                        .font(.caption)
                        .foregroundStyle(textSecondary)
                }

                Spacer()

                if isRecommended {
                    Text("Recommended")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accentBlue.opacity(0.16), in: Capsule())
                }
            }

            Text(target.promptGuidance)
                .font(.caption)
                .foregroundStyle(textSecondary)

            promptPanel(title: "\(title) Prompt", body: brief.executionPrompt(for: target))

            HStack {
                Button("Copy Prompt") {
                    copyPrompt(for: target, brief: brief)
                }
                .buttonStyle(.bordered)

                if isRecommended {
                    Button(target.label) {
                        store.promoteLatestBrief(for: projectName, to: target)
                        reloadDocument()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(target.label) {
                        store.promoteLatestBrief(for: projectName, to: target)
                        reloadDocument()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(panelSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func documentSection(
        title: String,
        subtitle: String,
        text: Binding<String>,
        minHeight: CGFloat = 140
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(textPrimary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(textSecondary)

            TextEditor(text: text)
                .font(.body)
                .foregroundStyle(textPrimary)
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
        }
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(panelStroke)
                .frame(height: 1)
        }
    }

    private func promptPanel(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(textSecondary)
            Text(body)
                .font(.callout)
                .foregroundStyle(textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(panelSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func sectionList(_ title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(textSecondary)
            ForEach(items, id: \.self) { item in
                Text("- \(item)")
                    .font(.callout)
                    .foregroundStyle(textPrimary)
            }
        }
    }

    private func binding(for keyPath: WritableKeyPath<ProjectPlanningDocument, String>) -> Binding<String> {
        Binding(
            get: { document[keyPath: keyPath] },
            set: { newValue in
                document[keyPath: keyPath] = newValue
                document.workingDirectory = workingDirectory
                store.save(document: document)
            }
        )
    }

    private func draftBrief() {
        document.workingDirectory = workingDirectory
        store.save(document: document)
        reloadDocument()
        _ = store.draftBrief(for: projectName, workingDirectory: workingDirectory)
        reloadDocument()
    }

    private func copyPrompt(for target: CortanaPromotionTarget, brief: CortanaBrief) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            brief.executionPrompt(for: target),
            forType: .string
        )
        copiedPromptTarget = target
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedPromptTarget == target {
                copiedPromptTarget = nil
            }
        }
    }

    private func recommendedTarget(for brief: CortanaBrief) -> CortanaPromotionTarget {
        ModelCatalog.family(for: brief.recommendedModelId) == .codex ? .codex : .claude
    }

    private var absoluteDateLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: document.updatedAt)
    }

    private var latestBriefStatus: String {
        document.latestBrief == nil ? "Draft" : "Brief Ready"
    }

    private var promptLaneLabel: String {
        document.latestBrief.map { ModelCatalog.label(for: $0.recommendedModelId) } ?? "Claude + Codex"
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                canvas,
                Color(red: 0.11, green: 0.12, blue: 0.13),
                Color(red: 0.10, green: 0.11, blue: 0.12)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func propertyRow(_ title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textSecondary)
                .frame(width: 14, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(textSecondary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keyValueBlock(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(textSecondary)
            Text(value)
                .font(.callout)
                .foregroundStyle(textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reloadDocument() {
        document = store.document(for: projectName, workingDirectory: workingDirectory)
        referenceSnapshot = store.referenceSnapshot(for: projectName, workingDirectory: workingDirectory)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
