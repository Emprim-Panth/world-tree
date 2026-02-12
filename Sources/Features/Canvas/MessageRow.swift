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

    @ViewBuilder
    private var markdownContent: some View {
        let segments = Self.parseContentSegments(message.content)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    if let attributed = try? AttributedString(
                        markdown: text,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    ) {
                        Text(attributed)
                            .textSelection(.enabled)
                            .font(.body)
                    } else {
                        Text(text)
                            .textSelection(.enabled)
                            .font(.body)
                    }

                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
                }
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

    // MARK: - Content Segment Parsing

    enum ContentSegment {
        case text(String)
        case code(String, language: String?)
    }

    /// Split message content into text and fenced code block segments
    static func parseContentSegments(_ content: String) -> [ContentSegment] {
        var segments: [ContentSegment] = []
        let lines = content.components(separatedBy: "\n")
        var currentText: [String] = []
        var currentCode: [String] = []
        var inCodeBlock = false
        var codeLanguage: String?

        for line in lines {
            if !inCodeBlock && line.hasPrefix("```") {
                // Start of code block
                let text = currentText.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(.text(text))
                }
                currentText = []
                inCodeBlock = true
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLanguage = lang.isEmpty ? nil : lang
            } else if inCodeBlock && line.hasPrefix("```") {
                // End of code block
                let code = currentCode.joined(separator: "\n")
                segments.append(.code(code, language: codeLanguage))
                currentCode = []
                inCodeBlock = false
                codeLanguage = nil
            } else if inCodeBlock {
                currentCode.append(line)
            } else {
                currentText.append(line)
            }
        }

        // Flush remaining content
        if inCodeBlock {
            // Unclosed code block — treat as code anyway
            let code = currentCode.joined(separator: "\n")
            if !code.isEmpty {
                segments.append(.code(code, language: codeLanguage))
            }
        } else {
            let text = currentText.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(.text(text))
            }
        }

        return segments
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var isHoveringCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Language badge + copy button
            if language != nil || isHoveringCode {
                HStack {
                    if let language {
                        Text(language)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                    }
                    Spacer()
                    if isHoveringCode {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 8)
                        .padding(.vertical, 2)
                    }
                }
                .background(Color.black.opacity(0.15))
            }

            // Code content with syntax highlighting
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlightedCode)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .init(white: 0.1, alpha: 1.0)))
        .cornerRadius(6)
        .onHover { isHoveringCode = $0 }
    }

    private var highlightedCode: AttributedString {
        SyntaxHighlighter.highlight(code, language: language)
    }
}

// MARK: - Syntax Highlighter

enum SyntaxHighlighter {
    // Color palette (dark theme)
    static let keywordColor = Color(nsColor: .init(red: 0.55, green: 0.55, blue: 1.0, alpha: 1.0))   // Blue-purple
    static let stringColor = Color(nsColor: .init(red: 0.87, green: 0.44, blue: 0.36, alpha: 1.0))    // Salmon
    static let commentColor = Color(nsColor: .init(red: 0.45, green: 0.55, blue: 0.45, alpha: 1.0))   // Muted green
    static let typeColor = Color(nsColor: .init(red: 0.35, green: 0.78, blue: 0.76, alpha: 1.0))      // Teal
    static let numberColor = Color(nsColor: .init(red: 0.82, green: 0.67, blue: 0.47, alpha: 1.0))    // Gold
    static let defaultColor = Color(nsColor: .init(white: 0.85, alpha: 1.0))                           // Light gray

    static let swiftKeywords: Set<String> = [
        "import", "func", "var", "let", "struct", "class", "enum", "protocol", "extension",
        "if", "else", "guard", "switch", "case", "default", "for", "while", "repeat",
        "return", "throw", "throws", "try", "catch", "do", "in", "where",
        "self", "Self", "super", "init", "deinit", "nil", "true", "false",
        "public", "private", "internal", "fileprivate", "open", "static", "final",
        "override", "mutating", "async", "await", "actor", "some", "any",
        "typealias", "associatedtype", "weak", "unowned", "lazy", "defer",
        "@MainActor", "@State", "@Binding", "@Published", "@Observable", "@Environment",
    ]

    static let swiftTypes: Set<String> = [
        "String", "Int", "Double", "Float", "Bool", "Array", "Dictionary", "Set",
        "Optional", "Result", "Error", "URL", "Data", "Date", "UUID",
        "View", "Text", "VStack", "HStack", "Button", "List", "NavigationView",
        "Color", "Image", "Spacer", "ScrollView", "Group", "ForEach",
    ]

    static let rustKeywords: Set<String> = [
        "fn", "let", "mut", "const", "struct", "enum", "impl", "trait", "pub", "use",
        "mod", "crate", "self", "super", "if", "else", "match", "for", "while", "loop",
        "return", "break", "continue", "as", "in", "where", "async", "await", "move",
        "unsafe", "ref", "type", "dyn", "true", "false",
    ]

    static let tsKeywords: Set<String> = [
        "function", "const", "let", "var", "class", "interface", "type", "enum",
        "import", "export", "from", "default", "if", "else", "switch", "case",
        "for", "while", "do", "return", "throw", "try", "catch", "finally",
        "new", "this", "super", "extends", "implements", "async", "await",
        "true", "false", "null", "undefined", "typeof", "instanceof", "of", "in",
        "yield", "break", "continue", "void", "never", "any", "string", "number", "boolean",
    ]

    static let pythonKeywords: Set<String> = [
        "def", "class", "import", "from", "as", "if", "elif", "else", "for", "while",
        "return", "yield", "raise", "try", "except", "finally", "with", "as",
        "lambda", "pass", "break", "continue", "and", "or", "not", "in", "is",
        "True", "False", "None", "self", "async", "await", "global", "nonlocal",
    ]

    static let bashKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
        "function", "return", "exit", "echo", "export", "source", "local", "readonly",
        "cd", "ls", "rm", "cp", "mv", "mkdir", "grep", "sed", "awk", "find", "xargs",
        "git", "npm", "cargo", "swift", "xcodebuild", "brew",
    ]

    static func highlight(_ code: String, language: String?) -> AttributedString {
        let keywords: Set<String>
        let types: Set<String>
        let commentPrefix: String

        switch language?.lowercased() {
        case "swift": keywords = swiftKeywords; types = swiftTypes; commentPrefix = "//"
        case "rust", "rs": keywords = rustKeywords; types = []; commentPrefix = "//"
        case "typescript", "ts", "javascript", "js", "tsx", "jsx": keywords = tsKeywords; types = []; commentPrefix = "//"
        case "python", "py": keywords = pythonKeywords; types = []; commentPrefix = "#"
        case "bash", "sh", "zsh", "shell": keywords = bashKeywords; types = []; commentPrefix = "#"
        default: keywords = []; types = []; commentPrefix = "//"
        }

        // If no language specified or unknown, return plain with default color
        if keywords.isEmpty {
            var attr = AttributedString(code)
            attr.foregroundColor = defaultColor
            return attr
        }

        var result = AttributedString()
        let lines = code.components(separatedBy: "\n")

        for (lineIdx, line) in lines.enumerated() {
            if lineIdx > 0 {
                var newline = AttributedString("\n")
                newline.foregroundColor = defaultColor
                result += newline
            }

            // Check if line is a comment
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(commentPrefix) {
                var commentAttr = AttributedString(line)
                commentAttr.foregroundColor = commentColor
                result += commentAttr
                continue
            }

            // Tokenize and colorize
            result += tokenizeLine(line, keywords: keywords, types: types)
        }

        return result
    }

    private static func tokenizeLine(_ line: String, keywords: Set<String>, types: Set<String>) -> AttributedString {
        var result = AttributedString()
        var current = line.startIndex
        let end = line.endIndex

        while current < end {
            let ch = line[current]

            // String literal
            if ch == "\"" || ch == "'" || ch == "`" {
                let quote = ch
                var strEnd = line.index(after: current)
                while strEnd < end && line[strEnd] != quote {
                    if line[strEnd] == "\\" && line.index(after: strEnd) < end {
                        strEnd = line.index(after: strEnd) // skip escaped char
                    }
                    strEnd = line.index(after: strEnd)
                }
                if strEnd < end { strEnd = line.index(after: strEnd) } // include closing quote
                var attr = AttributedString(String(line[current..<strEnd]))
                attr.foregroundColor = stringColor
                result += attr
                current = strEnd
                continue
            }

            // Number literal
            if ch.isNumber || (ch == "." && current < line.index(before: end) && line[line.index(after: current)].isNumber) {
                var numEnd = line.index(after: current)
                while numEnd < end && (line[numEnd].isNumber || line[numEnd] == "." || line[numEnd] == "_" || line[numEnd] == "x" || line[numEnd].isHexDigit) {
                    numEnd = line.index(after: numEnd)
                }
                var attr = AttributedString(String(line[current..<numEnd]))
                attr.foregroundColor = numberColor
                result += attr
                current = numEnd
                continue
            }

            // Word (keyword, type, or identifier)
            if ch.isLetter || ch == "_" || ch == "@" {
                var wordEnd = line.index(after: current)
                while wordEnd < end && (line[wordEnd].isLetter || line[wordEnd].isNumber || line[wordEnd] == "_") {
                    wordEnd = line.index(after: wordEnd)
                }
                let word = String(line[current..<wordEnd])
                var attr = AttributedString(word)

                if keywords.contains(word) {
                    attr.foregroundColor = keywordColor
                } else if types.contains(word) || (word.first?.isUppercase == true && word.count > 1) {
                    attr.foregroundColor = typeColor
                } else {
                    attr.foregroundColor = defaultColor
                }

                result += attr
                current = wordEnd
                continue
            }

            // Everything else (operators, punctuation, whitespace)
            var attr = AttributedString(String(ch))
            attr.foregroundColor = defaultColor
            result += attr
            current = line.index(after: current)
        }

        return result
    }
}
