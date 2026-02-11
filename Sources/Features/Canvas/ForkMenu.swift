import SwiftUI

/// Sheet for creating a new branch from a message
struct ForkMenu: View {
    let sourceMessage: Message
    @Binding var branchType: BranchType
    let branch: Branch?
    let onCreated: (String) -> Void

    @State private var title: String = ""
    @State private var selectedModel: String = CortanaConstants.defaultModel
    @State private var implementationNote: String = ""
    @State private var workingDirectory: String = ""
    @State private var isCreating: Bool = false
    @State private var error: String?

    private let models = [
        ("Auto", CortanaConstants.defaultModel),
        ("Opus", "claude-opus-4-6"),
        ("Sonnet", "claude-sonnet-4-5-20250929"),
        ("Haiku", "claude-haiku-4-5-20251001"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.orange)
                Text("Branch from message")
                    .font(.headline)
            }

            // Source message preview
            VStack(alignment: .leading, spacing: 4) {
                Text(sourceMessage.role == .user ? "You" : "Cortana")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sourceMessage.content)
                    .lineLimit(3)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.quaternary)
            .cornerRadius(8)

            Divider()

            // Branch type
            VStack(alignment: .leading, spacing: 6) {
                Text("Branch type")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Picker("Type", selection: $branchType) {
                    Label("Conversation", systemImage: "bubble.left")
                        .tag(BranchType.conversation)
                    Label("Implementation", systemImage: "gearshape")
                        .tag(BranchType.implementation)
                    Label("Exploration", systemImage: "magnifyingglass")
                        .tag(BranchType.exploration)
                }
                .pickerStyle(.segmented)
            }

            // Title
            TextField("Branch title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)

            // Model selection
            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Picker("Model", selection: $selectedModel) {
                    ForEach(models, id: \.1) { name, id in
                        Text(name).tag(id)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Implementation note (only for implementation branches)
            if branchType == .implementation {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Implementation instruction")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    TextEditor(text: $implementationNote)
                        .frame(height: 60)
                        .font(.callout)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary)
                        )
                }
            }

            // Working directory override — for branching into a different project
            VStack(alignment: .leading, spacing: 6) {
                Text("Working directory")
                    .font(.subheadline)
                    .fontWeight(.medium)
                HStack {
                    TextField("Inherit from tree", text: $workingDirectory)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = URL(fileURLWithPath: "\(FileManager.default.homeDirectoryForCurrentUser.path)/Development")
                        if panel.runModal() == .OK, let url = panel.url {
                            workingDirectory = url.path
                        }
                    }
                    .controlSize(.small)
                }
                Text("Leave empty to inherit from parent tree")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Actions
            HStack {
                Button("Cancel") {
                    onCreated("") // Will be ignored since showForkSheet closes
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(branchType == .implementation ? "Dispatch" : "Create Branch") {
                    createBranch()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func createBranch() {
        guard let parentBranch = branch else { return }
        isCreating = true
        error = nil

        do {
            // Build context
            let context: String
            if branchType == .implementation {
                context = try ContextBuilder.buildImplementationContext(
                    parentBranch: parentBranch,
                    forkMessageId: sourceMessage.id,
                    instruction: implementationNote.isEmpty ? nil : implementationNote
                )
            } else {
                context = try ContextBuilder.buildForkContext(
                    parentBranch: parentBranch,
                    forkMessageId: sourceMessage.id
                )
            }

            let branchTitle = title.isEmpty ? nil : title

            // Create the branch — pass explicit cwd if user overrode it
            let branchCwd = workingDirectory.isEmpty ? nil : workingDirectory

            let newBranch = try TreeStore.shared.createBranch(
                treeId: parentBranch.treeId,
                parentBranch: parentBranch.id,
                forkFromMessage: sourceMessage.id,
                type: branchType,
                title: branchTitle,
                model: selectedModel,
                contextSnapshot: context,
                workingDirectory: branchCwd
            )

            onCreated(newBranch.id)
        } catch {
            self.error = error.localizedDescription
            isCreating = false
        }
    }
}
