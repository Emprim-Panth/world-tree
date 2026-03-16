import SwiftUI

// MARK: - Starfleet Dispatch Sheet

/// Modal for dispatching a task to a specific Starfleet crew member.
/// Uses the same workflow planner as Command Center so Cortana owns model choice.
struct StarfleetDispatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let agent: StarfleetAgent

    @State private var message = ""
    @State private var selectedProjectPath = ""
    @State private var selectedModelId = Self.autoModelId
    @State private var selectedTemplateId = ""
    @State private var compilationMode = "craft"
    @State private var isDispatching = false
    @State private var dispatchStatus: String?

    @StateObject private var roster = StarfleetRoster.shared
    @StateObject private var providerManager = ProviderManager.shared

    private let modes = ["craft", "systems", "vocab", "full", "lean"]
    private static let autoModelId = "auto"

    private var projects: [CachedProject] {
        (try? ProjectCache().getAll()) ?? []
    }

    private var selectedProject: CachedProject? {
        projects.first { $0.path == selectedProjectPath }
    }

    private var selectedTemplate: WorkflowTemplate? {
        WorkflowTemplate.all.first { $0.id == selectedTemplateId }
    }

    private var workflowPlan: CortanaWorkflowExecutionPlan {
        CortanaWorkflowPlanner.plan(
            message: message,
            preferredModelId: selectedModelId == Self.autoModelId ? nil : selectedModelId,
            template: selectedTemplate
        )
    }

    private var modelOptions: [(id: String, label: String)] {
        [(Self.autoModelId, "Auto")] + providerManager.availableModelOptions.map { ($0.id, $0.label) }
    }

    var body: some View {
        VStack(spacing: 16) {
            agentHeader
            Divider()
            projectPicker
            controlPickers
            promptEditor
            workflowSummary
            directoryInfo
            actions
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .onAppear {
            if selectedProjectPath.isEmpty, let first = projects.first {
                selectedProjectPath = first.path
            }
        }
    }

    private var agentHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(agent.agentColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: agent.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(agent.agentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Dispatch to \(agent.displayName)")
                        .font(.headline)

                    Text(agent.tier.rawValue.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(agent.tierColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(agent.tierColor.opacity(0.12))
                        .cornerRadius(3)
                }

                Text(agent.domain)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private var projectPicker: some View {
        Picker("Project", selection: $selectedProjectPath) {
            ForEach(projects, id: \.path) { project in
                HStack {
                    Image(systemName: project.type.icon)
                    Text(project.name)
                }
                .tag(project.path)
            }
        }
        .pickerStyle(.menu)
    }

    private var controlPickers: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Workflow")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("Workflow", selection: $selectedTemplateId) {
                    Text("None").tag("")
                    ForEach(WorkflowTemplate.all) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("Model", selection: $selectedModelId) {
                    ForEach(modelOptions, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Compile Mode")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("Mode", selection: $compilationMode) {
                    ForEach(modes, id: \.self) { mode in
                        Text(mode).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private var promptEditor: some View {
        TextEditor(text: $message)
            .font(.system(size: 12))
            .frame(minHeight: 100)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.quaternary)
            )
            .overlay(alignment: .topLeading) {
                if message.isEmpty {
                    Text("Describe the task for \(agent.displayName)...")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
    }

    private var workflowSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selectedTemplate {
                HStack(spacing: 6) {
                    Image(systemName: selectedTemplate.icon)
                        .foregroundStyle(.cyan)
                    Text(selectedTemplate.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                summaryBadge(title: "Primary", value: ModelCatalog.label(for: workflowPlan.primaryModelId), color: .blue)

                if let reviewer = workflowPlan.reviewer {
                    summaryBadge(
                        title: reviewer.mode.label,
                        value: ModelCatalog.label(for: reviewer.modelId),
                        color: reviewer.mode == .qaChain ? .green : .orange
                    )
                }

                Spacer()
            }

            Text(workflowPlan.primaryReason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Agent default: \(ModelCatalog.label(for: ModelCatalog.canonicalModelId(for: agent.model) ?? "claude-sonnet-4-6"))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(10)
    }

    private var directoryInfo: some View {
        Group {
            if let project = selectedProject {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(project.path)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)

                    Spacer()

                    if let status = dispatchStatus {
                        Text(status)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(status.contains("Error") ? .red : .green)
                    }
                }
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var actions: some View {
        HStack {
            if !agent.triggers.isEmpty {
                HStack(spacing: 3) {
                    ForEach(agent.triggers.prefix(4), id: \.self) { trigger in
                        Text(trigger)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .cornerRadius(2)
                    }
                }
            }

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                dispatchTask()
            } label: {
                if isDispatching {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Compiling...")
                    }
                } else {
                    Label("Dispatch", systemImage: "paperplane.fill")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(
                message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || selectedProject == nil
                || isDispatching
            )
        }
    }

    private func dispatchTask() {
        guard let project = selectedProject,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        isDispatching = true
        dispatchStatus = nil

        Task {
            _ = await roster.dispatchToAgent(
                agentId: agent.id,
                message: message,
                project: project.name,
                workingDirectory: project.path,
                model: selectedModelId == Self.autoModelId ? nil : selectedModelId,
                template: selectedTemplate,
                mode: compilationMode
            )

            isDispatching = false
            dispatchStatus = selectedTemplate?.reviewMode.runsAutomatically == true ? "QA chain armed" : "Dispatched"

            try? await Task.sleep(for: .milliseconds(600))
            dismiss()
        }
    }

    private func summaryBadge(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}
