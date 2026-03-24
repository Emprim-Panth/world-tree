import SwiftUI

/// Quick-dispatch modal for firing background tasks from the Command Center.
/// Fires via GatewayClient — no local LLM provider needed.
struct DispatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let projects: [String]
    let onDispatch: (String, String, String?) -> Void

    @State private var message = ""
    @State private var selectedProject = ""
    @State private var selectedModel = "claude-sonnet-4-6"

    private let models = [
        "claude-sonnet-4-6",
        "claude-opus-4-6",
        "claude-haiku-4-5-20251001"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Dispatch", systemImage: "paperplane.fill").font(.title3.bold())
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
            }

            Divider()

            Picker("Project", selection: $selectedProject) {
                Text("Select project…").tag("")
                ForEach(projects.sorted(), id: \.self) { Text($0).tag($0) }
            }

            Picker("Model", selection: $selectedModel) {
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }

            TextField("Describe the task…", text: $message, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)

            HStack {
                Spacer()
                Button("Dispatch") {
                    guard !message.isEmpty, !selectedProject.isEmpty else { return }
                    onDispatch(message, selectedProject, selectedModel)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || selectedProject.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 260)
        .onAppear {
            if selectedProject.isEmpty { selectedProject = projects.sorted().first ?? "" }
        }
    }
}
