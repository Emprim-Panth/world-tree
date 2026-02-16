import SwiftUI

/// Individual section in the document (replaces message bubble)
struct DocumentSectionView: View {
    let section: DocumentSection
    let isHovered: Bool
    let onEdit: (AttributedString) -> Void
    let onBranch: () -> Void

    @State private var isEditing = false
    @State private var editedContent: AttributedString

    init(
        section: DocumentSection,
        isHovered: Bool,
        onEdit: @escaping (AttributedString) -> Void,
        onBranch: @escaping () -> Void
    ) {
        self.section = section
        self.isHovered = isHovered
        self.onEdit = onEdit
        self.onBranch = onBranch
        _editedContent = State(initialValue: section.content)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Author indicator (subtle, left margin)
            AuthorIndicator(author: section.author)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 8) {
                // Content (editable if user-authored and enabled)
                if isEditing && section.isEditable {
                    EditableTextView(
                        content: $editedContent,
                        onCommit: {
                            onEdit(editedContent)
                            isEditing = false
                        }
                    )
                    .frame(minHeight: 60)
                } else {
                    Text(section.content)
                        .textSelection(.enabled)
                        .onTapGesture(count: 2) {
                            if section.isEditable {
                                isEditing = true
                            }
                        }
                }

                // Metadata (code blocks, tool calls, etc.)
                if let toolCalls = section.metadata.toolCalls {
                    ForEach(toolCalls) { call in
                        ToolCallView(call: call)
                    }
                }

                if let codeBlocks = section.metadata.codeBlocks {
                    ForEach(codeBlocks) { block in
                        CodeBlockView(block: block)
                    }
                }

                // Timestamp and tokens (subtle)
                HStack(spacing: 8) {
                    Text(section.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if let tokens = section.metadata.tokens {
                        Text("\(tokens.total) tokens")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 8)

            Spacer()

            // Branch button (appears on hover)
            if isHovered && section.branchPoint {
                Button(action: onBranch) {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: 12))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .help("Branch from here")
            }
        }
        .padding(.horizontal, 0)
        .background(
            isHovered ? Color.blue.opacity(0.05) : Color.clear
        )
    }
}

// MARK: - Author Indicator

struct AuthorIndicator: View {
    let author: Author

    var body: some View {
        Circle()
            .fill(author.color.gradient)
            .overlay {
                Text(initial)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
    }

    private var initial: String {
        switch author {
        case .user(let name):
            return String(name.prefix(1).uppercased())
        case .assistant:
            return "💠"
        case .system:
            return "⚙︎"
        }
    }
}

// MARK: - Tool Call View

struct ToolCallView: View {
    let call: ToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                Text(call.name)
                    .font(.caption.monospaced().bold())
                Spacer()
                Text(call.status == .success ? "✓" : "...")
                    .font(.caption2)
                    .foregroundColor(statusColor)
            }

            if !call.input.isEmpty {
                Text(call.input)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }

            if let output = call.output, !output.isEmpty {
                Text(output)
                    .font(.caption.monospaced())
                    .foregroundColor(.primary)
                    .lineLimit(5)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    private var statusIcon: String {
        switch call.status {
        case .pending: return "clock"
        case .running: return "arrow.clockwise"
        case .success: return "checkmark.circle"
        case .error: return "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch call.status {
        case .pending: return .orange
        case .running: return .blue
        case .success: return .green
        case .error: return .red
        }
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let block: CodeBlock

    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                if !block.language.isEmpty {
                    Text(block.language.uppercased())
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                }

                if let path = block.filePath {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundColor(.blue)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: copyCode) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(block.code, forType: .string)
        isCopied = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }
}

// MARK: - Editable Text View

struct EditableTextView: View {
    @Binding var content: AttributedString
    let onCommit: () -> Void

    @State private var text: String

    init(content: Binding<AttributedString>, onCommit: @escaping () -> Void) {
        _content = content
        self.onCommit = onCommit
        _text = State(initialValue: String(content.wrappedValue.characters))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(.body))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.blue, lineWidth: 2)
                )

            HStack {
                Button("Cancel") {
                    text = String(content.characters)
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    content = AttributedString(text)
                    onCommit()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
