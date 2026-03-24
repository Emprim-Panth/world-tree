import SwiftUI

/// BRAIN.md editor for a project. Left: plain-text editor. Right: rendered markdown preview.
/// Autosaves 1.5s after last keystroke via debounce.
struct BrainEditorView: View {
    @ObservedObject private var store = BrainFileStore.shared
    @State private var selectedProject: String = ""
    @State private var draft: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var saveStatus: SaveStatus = .saved

    private enum SaveStatus {
        case saved, saving, error(String)

        var label: String {
            switch self {
            case .saved: "Saved"
            case .saving: "Saving…"
            case .error(let msg): "Error: \(msg)"
            }
        }
        var color: Color {
            switch self {
            case .saved: .secondary
            case .saving: .orange
            case .error: .red
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if selectedProject.isEmpty {
                emptyState
            } else {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        editor
                            .frame(width: geo.size.width / 2)
                        Divider()
                        preview
                            .frame(width: geo.size.width / 2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { selectFirstProject() }
    }

    // MARK: — Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain").foregroundStyle(.secondary)
            Text("Brain Editor").font(.headline)

            Spacer()

            projectPicker

            Text(saveStatus.label)
                .font(.caption)
                .foregroundStyle(saveStatus.color)

            Button("Save") { saveNow() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var projectPicker: some View {
        let projects = Array(store.content.keys).sorted()
        if projects.isEmpty {
            Text("No projects loaded").font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Project", selection: $selectedProject) {
                ForEach(projects, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            .onChange(of: selectedProject) { _, new in
                draft = store.content[new] ?? ""
                store.watch(project: new)
            }
        }
    }

    // MARK: — Editor

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.system(size: 12, design: .monospaced))
            .padding(12)
            .frame(maxHeight: .infinity)
            .onChange(of: draft) { _, _ in scheduleSave() }
    }

    // MARK: — Preview

    private var preview: some View {
        ScrollView {
            Text((try? AttributedString(markdown: draft, options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            ))) ?? AttributedString(draft))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: — Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No projects found")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Open a project's BRAIN.md via the selector above, or start a Claude session to populate it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: — Autosave

    private func scheduleSave() {
        saveTask?.cancel()
        saveStatus = .saving
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        guard !selectedProject.isEmpty else { return }
        do {
            try store.write(draft, for: selectedProject)
            saveStatus = .saved
        } catch {
            saveStatus = .error(error.localizedDescription)
        }
    }

    // MARK: — Helpers

    private func selectFirstProject() {
        // Seed from CompassStore project names
        let projects = CompassStore.shared.states.keys.sorted()
        guard let first = projects.first else { return }
        for p in projects { store.watch(project: p) }
        selectedProject = first
        draft = store.read(project: first) ?? ""
    }
}
