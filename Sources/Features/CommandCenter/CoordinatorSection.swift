import SwiftUI

// MARK: - Coordinator Section

/// Command Center panel showing active coordinator plans (Ollama-orchestrated multi-task goals).
struct CoordinatorSection: View {
    @ObservedObject private var coordinator = CoordinatorActor.shared
    @State private var isShowingNewPlan = false
    @State private var expandedPlanIds: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if coordinator.isDecomposing {
                decomposingBanner
            }

            if coordinator.activePlans.isEmpty && !coordinator.isDecomposing {
                emptyState
            } else {
                planList
            }
        }
        .sheet(isPresented: $isShowingNewPlan) {
            NewCoordinatorPlanSheet { goal, project, workingDirectory, model in
                Task {
                    await coordinator.startPlan(
                        goal: goal,
                        project: project,
                        workingDirectory: workingDirectory,
                        ollamaModel: model
                    )
                }
            }
            .frame(width: 540, height: 320)
        }
        .onAppear {
            coordinator.start()
        }
        .onDisappear {
            coordinator.stop()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 10))
                .foregroundStyle(.purple)
            Text("COORDINATOR")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.purple)

            if !coordinator.activePlans.filter(\.isActive).isEmpty {
                Text("\(coordinator.activePlans.filter(\.isActive).count) active")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.purple.opacity(0.7))
            }

            Spacer()

            Button {
                isShowingNewPlan = true
            } label: {
                Label("New Plan", systemImage: "plus")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(.purple)
        }
    }

    // MARK: - Decomposing Banner

    private var decomposingBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
            Text(coordinator.decompositionStatus)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        Button {
            isShowingNewPlan = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.purple.opacity(0.6))
                Text("Start a coordinator plan — let Ollama orchestrate multi-step work")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.purple.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Plan List

    private var planList: some View {
        VStack(spacing: 6) {
            ForEach(coordinator.activePlans.prefix(8)) { plan in
                PlanCard(
                    plan: plan,
                    tasks: coordinator.planTasks[plan.id] ?? [],
                    isExpanded: expandedPlanIds.contains(plan.id),
                    onToggle: {
                        if expandedPlanIds.contains(plan.id) {
                            expandedPlanIds.remove(plan.id)
                        } else {
                            expandedPlanIds.insert(plan.id)
                        }
                    },
                    onCancel: {
                        coordinator.cancelPlan(plan.id)
                    }
                )
            }
        }
    }
}

// MARK: - Plan Card

private struct PlanCard: View {
    let plan: CoordinatorPlan
    let tasks: [CoordinatorTask]
    let isExpanded: Bool
    let onToggle: () -> Void
    let onCancel: () -> Void

    private var statusColor: Color {
        switch plan.status {
        case .planning: return .orange
        case .running: return .green
        case .paused: return .yellow
        case .completed: return .secondary
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)

                    Text(plan.goal)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    // Progress
                    if plan.taskCount > 0 {
                        Text("\(plan.completedTaskCount)/\(plan.taskCount)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    // Status badge
                    Text(plan.status.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(statusColor)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            // Progress bar
            if plan.taskCount > 0 && plan.isActive {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.purple.opacity(0.1))
                        Rectangle()
                            .fill(Color.purple.opacity(0.4))
                            .frame(width: geo.size.width * plan.progressFraction)
                    }
                }
                .frame(height: 2)
            }

            // Expanded task list
            if isExpanded && !tasks.isEmpty {
                VStack(spacing: 0) {
                    Divider()
                        .opacity(0.3)

                    ForEach(tasks) { task in
                        TaskRow(task: task)
                    }

                    // Cancel button for active plans
                    if plan.isActive {
                        Button("Cancel Plan", action: onCancel)
                            .font(.system(size: 10))
                            .foregroundStyle(.red.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .background(plan.isActive ? Color.purple.opacity(0.04) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.purple.opacity(plan.isActive ? 0.15 : 0.08), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Task Row

private struct TaskRow: View {
    let task: CoordinatorTask

    private var iconColor: Color {
        switch task.status {
        case .queued: return .secondary
        case .dispatched, .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .skipped: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.statusIcon)
                .font(.system(size: 9))
                .foregroundStyle(iconColor)
                .frame(width: 14)

            Text("\(task.sequence + 1).")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)

            Text(task.title)
                .font(.system(size: 10))
                .foregroundStyle(task.isTerminal ? .secondary : .primary)
                .lineLimit(1)

            Spacer()

            if let summary = task.resultSummary {
                Text(summary)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

// MARK: - New Plan Sheet

struct NewCoordinatorPlanSheet: View {
    let onSubmit: (String, String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var goal: String = ""
    @State private var project: String = ""
    @State private var workingDirectory: String = ""
    @State private var ollamaModel: String = "llama3.2"

    private var canSubmit: Bool {
        !goal.trimmingCharacters(in: .whitespaces).isEmpty &&
        !workingDirectory.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.purple)
                Text("New Coordinator Plan")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Goal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $goal)
                    .font(.system(size: 13))
                    .frame(height: 80)
                    .padding(6)
                    .background(Color(.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                Text("Describe what you want to accomplish in plain language. Ollama will decompose it into tasks.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("e.g. WorldTree", text: $project)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ollama Model")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("e.g. llama3.2", text: $ollamaModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 120)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Working Directory")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("/Users/evan/Development/WorldTree", text: $workingDirectory)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            Spacer()

            HStack {
                Spacer()
                Button("Start Plan") {
                    onSubmit(goal, project, workingDirectory, ollamaModel)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
    }
}
