import SwiftUI

// MARK: - Factory Pipeline View (Cortana 2.0 / NERVE)

/// Shows the Cortana 2.0 factory pipeline — projects flowing through INTAKE → DONE.
/// Reads from `FactoryStore` which subscribes to NERVE SSE at `/v2/nerve/stream`.
///
/// This view coexists with `FactoryFloorView` (legacy dispatch_queue Kanban).
/// The plan is to replace FactoryFloorView once NERVE is deployed.
struct FactoryPipelineView: View {
    @Environment(AppState.self) var appState
    private var store = FactoryStore.shared

    @State private var intakePrompt: String    = ""
    @State private var isSubmitting: Bool      = false
    @State private var submitError: String?    = nil
    @State private var selectedProject: FactoryProject? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            if let alert = store.systemAlert {
                SystemAlertBanner(alert: alert) {
                    store.systemAlert = nil
                }
            }
            intakeField
            Divider()
            content
        }
        .background(Color(NSColor.controlBackgroundColor))
        .task {
            await store.start()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.purple)
                    Text("Factory Pipeline 2.0")
                        .font(.title2)
                        .fontWeight(.bold)
                }
                HStack(spacing: 4) {
                    Circle()
                        .fill(store.isConnected ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(store.isConnected ? "NERVE connected" : "Waiting for NERVE…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Intake Field

    @ViewBuilder
    private var intakeField: some View {
        HStack(spacing: 10) {
            TextField("Describe a project to build…", text: $intakePrompt)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitProject() }

            Button(action: submitProject) {
                if isSubmitting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Submit", systemImage: "paperplane.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(intakePrompt.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)

        if let err = submitError {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let err = store.connectionError {
            ContentUnavailableView {
                Label("NERVE Unavailable", systemImage: "network.slash")
            } description: {
                Text(err)
            } actions: {
                Button("Retry") { Task { await store.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        } else if store.factoryProjects.isEmpty {
            ContentUnavailableView {
                Label("No Projects", systemImage: "tray")
            } description: {
                Text("Submit a prompt above to start the factory pipeline.")
            }
        } else {
            projectList
        }
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(store.factoryProjects) { project in
                    FactoryProjectRow(project: project)
                        .onTapGesture { selectedProject = project }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .sheet(item: $selectedProject) { project in
            FactoryProjectDetailSheet(project: project)
                .environment(appState)
        }
    }

    // MARK: - Submit

    private func submitProject() {
        let prompt = intakePrompt.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        submitError  = nil
        Task {
            do {
                try await store.submitProject(prompt: prompt)
                intakePrompt = ""
            } catch {
                submitError = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}

// MARK: - Project Row

private struct FactoryProjectRow: View {
    let project: FactoryProject

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.projectName ?? "Unnamed Project")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(project.intakePrompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                // State badge
                HStack(spacing: 4) {
                    if project.blocked {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 10))
                    }
                    if project.humanQuestion != nil {
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 10))
                    }
                    Image(systemName: project.state.icon)
                        .foregroundStyle(project.state.color)
                        .font(.system(size: 10, weight: .semibold))
                    Text(project.state.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(project.state.color)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(project.state.color.opacity(0.12))
                .clipShape(Capsule())
            }

            PipelineStagesView(project: project)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(project.blocked ? Color.red.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Pipeline Stages View

struct PipelineStagesView: View {
    let project: FactoryProject

    var body: some View {
        HStack(spacing: 3) {
            ForEach(FactoryState.pipelineOrder, id: \.self) { stage in
                stagePill(stage)
                if stage != .done {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func stagePill(_ stage: FactoryState) -> some View {
        let isCurrent  = project.state == stage
        let isComplete = stage.pipelineIndex < project.state.pipelineIndex
        let isBlocked  = isCurrent && project.blocked

        HStack(spacing: 3) {
            if isBlocked {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
            } else if isCurrent && project.humanQuestion != nil {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 8))
            } else {
                Image(systemName: stage.icon)
                    .font(.system(size: 8))
            }
            if isCurrent {
                Text(stage.displayName)
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(
            isBlocked  ? .red :
            isCurrent  ? stage.color :
            isComplete ? .green :
            Color.secondary.opacity(0.4)
        )
        .padding(.horizontal, isCurrent ? 6 : 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isCurrent ? stage.color.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isCurrent ? stage.color.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Project Detail Sheet

private struct FactoryProjectDetailSheet: View {
    @Environment(AppState.self) var appState
    let project: FactoryProject

    @State private var answerText: String = ""
    @State private var isAnswering: Bool   = false
    @State private var answerError: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.projectName ?? "Factory Project")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("id: \(project.id.prefix(8))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            }

            Divider()

            // Pipeline visualization
            Text("Pipeline State")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fontWeight(.semibold)
            PipelineStagesView(project: project)
                .padding(.vertical, 4)

            // Intake prompt
            GroupBox("Intake Prompt") {
                Text(project.intakePrompt)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }

            // Block reason
            if let reason = project.blockedReason, !reason.isEmpty {
                GroupBox {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(reason)
                            .font(.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                } label: {
                    Label("Blocked", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            // Human question (if any)
            if let question = project.humanQuestion {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(question)
                            .font(.body)
                        TextField("Your answer…", text: $answerText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                        if let err = answerError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                        Button(action: submitAnswer) {
                            if isAnswering {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Send Answer", systemImage: "arrowshape.turn.up.right.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(answerText.trimmingCharacters(in: .whitespaces).isEmpty || isAnswering)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                } label: {
                    Label("Agent Question", systemImage: "questionmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 400)
    }

    private func submitAnswer() {
        let answer = answerText.trimmingCharacters(in: .whitespaces)
        guard !answer.isEmpty, !isAnswering else { return }
        isAnswering = true
        answerError = nil
        Task {
            do {
                try await FactoryStore.shared.answerQuestion(projectId: project.id, answer: answer)
                answerText = ""
                dismiss()
            } catch {
                answerError = error.localizedDescription
            }
            isAnswering = false
        }
    }
}

// MARK: - System Alert Banner

private struct SystemAlertBanner: View {
    let alert:    SystemAlert
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: alert.kind.icon)
                .foregroundStyle(alert.kind == .diskPressure ? .yellow : .red)
                .font(.system(size: 14, weight: .semibold))
            Text(alert.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            alert.kind == .diskPressure
                ? Color.yellow.opacity(0.15)
                : Color.red.opacity(0.12)
        )
    }
}
