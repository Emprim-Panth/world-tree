import SwiftUI

// MARK: - Starfleet Dispatch Sheet

/// Modal for dispatching a task to a specific Starfleet crew member.
/// Compiles the agent's identity, then fires a dispatch through ClaudeBridge.
struct StarfleetDispatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let agent: StarfleetAgent

    @State private var message = ""
    @State private var selectedProjectPath = ""
    @State private var selectedModel: String
    @State private var compilationMode = "craft"
    @State private var isDispatching = false
    @State private var dispatchStatus: String?

    @StateObject private var roster = StarfleetRoster.shared

    private let models = ["haiku", "sonnet", "opus"]
    private let modes = ["craft", "systems", "vocab", "full", "lean"]

    init(agent: StarfleetAgent) {
        self.agent = agent
        _selectedModel = State(initialValue: agent.model)
    }

    private var projects: [CachedProject] {
        (try? ProjectCache().getAll()) ?? []
    }

    private var selectedProject: CachedProject? {
        projects.first { $0.path == selectedProjectPath }
    }

    var body: some View {
        VStack(spacing: 16) {
            agentHeader
            Divider()
            projectPicker
            modelAndModePickers
            promptEditor
            directoryInfo
            actions
        }
        .padding(20)
        .frame(width: 520, height: 440)
        .onAppear {
            if selectedProjectPath.isEmpty, let first = projects.first {
                selectedProjectPath = first.path
            }
        }
    }

    // MARK: - Agent Header

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

    // MARK: - Project Picker

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

    // MARK: - Model & Mode Pickers

    private var modelAndModePickers: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("Model", selection: $selectedModel) {
                    ForEach(models, id: \.self) { model in
                        Text(model.capitalized).tag(model)
                    }
                }
                .pickerStyle(.segmented)
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

    // MARK: - Prompt Editor

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

    // MARK: - Directory Info

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

    // MARK: - Actions

    private var actions: some View {
        HStack {
            // Trigger hints
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

    // MARK: - Dispatch

    private func dispatchTask() {
        guard let project = selectedProject,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isDispatching = true
        dispatchStatus = nil

        Task {
            let stream = await roster.dispatchToAgent(
                agentId: agent.id,
                message: message,
                project: project.name,
                workingDirectory: project.path,
                model: selectedModel,
                mode: compilationMode
            )

            isDispatching = false
            dispatchStatus = "Dispatched"

            // Consume stream in background — output tracked by JobOutputStreamStore
            Task {
                for await _ in stream {}
            }

            // Close sheet after brief delay so user sees the status
            try? await Task.sleep(for: .milliseconds(600))
            dismiss()
        }
    }
}
