import SwiftUI

/// Quick-dispatch modal for firing background tasks from the Command Center.
struct DispatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let projects: [CachedProject]
    let onDispatch: (String, CachedProject, String?) -> Void

    @State private var message = ""
    @State private var selectedProjectPath: String = ""
    @State private var selectedModel = "sonnet"

    private let models = ["haiku", "sonnet", "opus"]

    private var selectedProject: CachedProject? {
        projects.first { $0.path == selectedProjectPath }
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

            // Model picker
            Picker("Model", selection: $selectedModel) {
                ForEach(models, id: \.self) { model in
                    Text(model.capitalized).tag(model)
                }
            }
            .pickerStyle(.segmented)

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
                    onDispatch(message, project, selectedModel)
                    dismiss()
                } label: {
                    Label("Dispatch", systemImage: "paperplane.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedProject == nil)
            }
        }
        .padding(20)
        .frame(width: 480, height: 360)
    }
}
