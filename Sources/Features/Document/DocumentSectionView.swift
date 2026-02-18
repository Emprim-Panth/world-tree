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
                    MarkdownTextView(
                        content: section.content,
                        author: section.author
                    )
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
                        CodeBlockView(code: block.code, language: block.language.isEmpty ? nil : block.language)
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
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
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


// MARK: - Markdown Text View

/// Renders assistant content with markdown awareness.
/// Code fences (``` blocks) are extracted and rendered via CodeBlockView.
/// Everything else uses SwiftUI's built-in AttributedString markdown support.
struct MarkdownTextView: View {
    let content: AttributedString
    let author: Author

    var body: some View {
        let raw = String(content.characters)

        // For non-assistant messages, plain text is fine
        guard case .assistant = author else {
            return AnyView(
                Text(content)
                    .fixedSize(horizontal: false, vertical: true)
            )
        }

        // Parse markdown — use AttributedString(markdown:) for inline formatting
        let rendered = (try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? content

        return AnyView(
            MarkdownCodeFenceView(raw: raw, rendered: rendered)
        )
    }
}

/// Splits raw markdown text into prose + code fence segments and renders each.
struct MarkdownCodeFenceView: View {
    let raw: String
    let rendered: AttributedString

    var body: some View {
        let segments = parseSegments(raw)
        if segments.isEmpty {
            return AnyView(
                Text(rendered)
                    .fixedSize(horizontal: false, vertical: true)
            )
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .prose(let text):
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if let attr = try? AttributedString(
                                markdown: text,
                                options: AttributedString.MarkdownParsingOptions(
                                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                                )
                            ) {
                                Text(attr)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    case .codeBlock(let code, let language):
                        CodeBlockView(code: code, language: language.isEmpty ? nil : language)
                    }
                }
            }
        )
    }

    enum Segment {
        case prose(String)
        case codeBlock(String, String)
    }

    private func parseSegments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            if let fenceStart = remaining.range(of: "```") {
                // Text before the fence
                let before = String(remaining[remaining.startIndex..<fenceStart.lowerBound])
                if !before.isEmpty {
                    segments.append(.prose(before))
                }

                // Find language tag (rest of opening line)
                let afterFence = remaining[fenceStart.upperBound...]
                let langEnd = afterFence.firstIndex(of: "\n") ?? afterFence.endIndex
                let language = String(afterFence[afterFence.startIndex..<langEnd])

                let codeStart = langEnd < afterFence.endIndex ? afterFence.index(after: langEnd) : afterFence.endIndex
                let codeRegion = remaining[codeStart...]

                if let closingFence = codeRegion.range(of: "```") {
                    let code = String(codeRegion[codeRegion.startIndex..<closingFence.lowerBound])
                        .trimmingCharacters(in: .newlines)
                    segments.append(.codeBlock(code, language.trimmingCharacters(in: .whitespaces)))
                    remaining = codeRegion[closingFence.upperBound...]
                    // Skip leading newline after closing fence
                    if remaining.hasPrefix("\n") { remaining = remaining.dropFirst() }
                } else {
                    // Unclosed fence — treat as prose
                    segments.append(.prose(String(remaining)))
                    break
                }
            } else {
                segments.append(.prose(String(remaining)))
                break
            }
        }

        return segments
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
