import SwiftUI

struct MessageRow: View {
    let message: Message
    let onFork: (Message, BranchType) -> Void
    var onEdit: ((Message, String) -> Void)?

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Role gutter
            roleGutter
                .frame(width: 48, alignment: .trailing)
                .padding(.trailing, 8)

            // Accent bar
            RoundedRectangle(cornerRadius: 1)
                .fill(accentColor)
                .frame(width: 2)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                if message.role == .system {
                    systemContent
                } else if isEditing {
                    editingContent
                } else {
                    markdownContent
                }

                // Fork badge
                if message.hasBranches && !isEditing {
                    forkBadge
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Hover actions
            if isHovering && !isEditing && message.role != .system {
                hoverActions
                    .padding(.trailing, 4)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(isHovering ? Color.primary.opacity(0.02) : .clear)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Branch from here") {
                onFork(message, .conversation)
            }
            Button("Implementation branch") {
                onFork(message, .implementation)
            }
            Button("Exploration branch") {
                onFork(message, .exploration)
            }
            Divider()
            if message.role == .user, onEdit != nil {
                Button("Edit message") {
                    startEditing()
                }
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
            }
        }
    }

    // MARK: - Role Gutter

    private var roleGutter: some View {
        Group {
            switch message.role {
            case .user:
                Text("You")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            case .assistant:
                HStack(spacing: 2) {
                    Image(systemName: "diamond.fill")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                    Text("C")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.cyan)
                }
            case .system:
                Text("sys")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Accent Colors

    private var accentColor: Color {
        switch message.role {
        case .user: .blue.opacity(0.6)
        case .assistant: .cyan.opacity(0.6)
        case .system: .gray.opacity(0.3)
        }
    }

    // MARK: - Markdown Content

    private var markdownContent: some View {
        Group {
            if let attributed = try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
                    .textSelection(.enabled)
                    .font(.body)
            } else {
                Text(message.content)
                    .textSelection(.enabled)
                    .font(.body)
            }
        }
    }

    // MARK: - System Content

    private var systemContent: some View {
        Text(message.content)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    // MARK: - Fork Badge

    private var forkBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption2)
            Text("has branches")
                .font(.caption2)
        }
        .foregroundStyle(.orange.opacity(0.8))
        .padding(.top, 2)
    }

    // MARK: - Hover Actions

    private var hoverActions: some View {
        VStack(spacing: 4) {
            if message.role == .user, onEdit != nil {
                Button {
                    startEditing()
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit message")
            }

            Button {
                onFork(message, .conversation)
            } label: {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Branch from here")

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(.top, 4)
    }

    // MARK: - Editing

    private var editingContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $editText)
                .font(.body)
                .frame(minHeight: 40, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(8)

            HStack(spacing: 8) {
                Button("Cancel") {
                    isEditing = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button("Save & Branch") {
                    let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onEdit?(message, trimmed)
                    }
                    isEditing = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Text("Creates a new branch")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func startEditing() {
        editText = message.content
        isEditing = true
    }
}
