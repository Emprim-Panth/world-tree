import SwiftUI

/// Sheet for creating a new Claude Code session.
struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    var manager = SessionManager.shared
    var compassStore = CompassStore.shared

    @State private var selectedProject: String = ""
    @State private var skipPermissions = false
    @State private var resumeSession = false
    @State private var resumeID = ""

    private var projects: [String] {
        compassStore.states.keys.sorted()
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("New Session")
                .font(.title2.bold())

            Form {
                Picker("Project", selection: $selectedProject) {
                    Text("Select...").tag("")
                    ForEach(projects, id: \.self) { project in
                        Text(project).tag(project)
                    }
                }

                Toggle("Resume previous session", isOn: $resumeSession)
                if resumeSession {
                    TextField("Session ID", text: $resumeID)
                        .font(.system(.body, design: .monospaced))
                }

                Toggle("Skip permissions", isOn: $skipPermissions)
                if skipPermissions {
                    Text("Bypasses all tool safety checks. Use with caution.")
                        .font(.caption)
                        .foregroundStyle(Palette.warning)
                }
            }
            .formStyle(.grouped)

            if !selectedProject.isEmpty && manager.hasConflict(project: selectedProject) {
                Label("Another session is already active for this project", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.warning)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Start Session") {
                    guard !selectedProject.isEmpty else { return }
                    let path = compassStore.states[selectedProject]?.path ?? "~/Development/\(selectedProject)"
                    let expanded = (path as NSString).expandingTildeInPath

                    _ = manager.createSession(
                        project: selectedProject,
                        projectPath: expanded,
                        skipPermissions: skipPermissions,
                        resumeID: resumeSession ? resumeID : nil
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedProject.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 450)
        .onAppear {
            if selectedProject.isEmpty, let first = projects.first {
                selectedProject = first
            }
        }
    }
}
