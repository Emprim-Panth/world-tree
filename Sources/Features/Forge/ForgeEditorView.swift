import SwiftUI

/// Text editor panel for Forge. Monospaced, dirty-tracking, Cmd+S to save.
struct ForgeEditorView: View {
    @Bindable var store: ForgeStore

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            TextEditor(text: $store.draftContent)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .background(Palette.codeBackground)
        }
        .keyboardShortcut("s", modifiers: .command)
        .onReceive(NotificationCenter.default.publisher(for: .forgeSaveRequested)) { _ in
            store.saveEdit()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil.line")
                .foregroundStyle(Palette.accent)
                .font(.system(size: 13))

            if let url = store.selectedURL {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
            }

            if store.isDirty {
                Circle()
                    .fill(Palette.dirty)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }

            Spacer()

            Button("Cancel") {
                store.cancelEdit()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 12))

            Button("Save") {
                store.saveEdit()
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!store.isDirty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.cardBackground)
    }
}

// MARK: - Notification

extension Notification.Name {
    static let forgeSaveRequested = Notification.Name("forgeSaveRequested")
}
