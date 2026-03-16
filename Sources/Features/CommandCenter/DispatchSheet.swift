import SwiftUI

/// Quick-dispatch modal for firing background tasks from the Command Center.
struct DispatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let projects: [CachedProject]
    let onDispatch: (String, CachedProject, String?, WorkflowTemplate?) -> Void

    @State private var message = ""
    @State private var selectedProjectPath: String = ""
    @State private var selectedModelId = Self.autoModelId
    @State private var selectedTemplateId = ""

    @StateObject private var providerManager = ProviderManager.shared

    private static let autoModelId = "auto"

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
            // Header
            HStack {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(.blue)
                Text("New Dispatch")
                    .font(.headline)
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

            // Project picker — keyed by path to avoid index-shift bugs
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
            .onAppear {
                if selectedProjectPath.isEmpty, let first = projects.first {
                    selectedProjectPath = first.path
                }
            }

            HStack(spacing: 12) {
                Picker("Workflow", selection: $selectedTemplateId) {
                    Text("None").tag("")
                    ForEach(WorkflowTemplate.all) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                .pickerStyle(.menu)

                Picker("Model", selection: $selectedModelId) {
                    ForEach(modelOptions, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
            }

            // Task description
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
                        Text("Describe the task...")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            workflowSummary

            // Working directory info
            if let project = selectedProject {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(project.path)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .foregroundStyle(.tertiary)
            }

            // Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let project = selectedProject else { return }
                    onDispatch(
                        message,
                        project,
                        selectedModelId == Self.autoModelId ? nil : selectedModelId,
                        selectedTemplate
                    )
                    dismiss()
                } label: {
                    Label("Dispatch", systemImage: "paperplane.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedProject == nil)
            }
        }
        .padding(20)
        .frame(width: 520, height: 430)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(10)
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
