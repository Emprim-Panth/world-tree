import SwiftUI

/// Renders streaming text with markdown formatting applied.
/// Handles partial markdown gracefully — incomplete code blocks show as plain text.
struct StreamingMarkdownView: View {
    let text: String

    var body: some View {
        let segments = MessageRow.parseContentSegments(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let content):
                    if let attributed = try? AttributedString(
                        markdown: content,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    ) {
                        Text(attributed)
                            .font(.body)
                            .textSelection(.enabled)
                    } else {
                        Text(content)
                            .font(.body)
                            .textSelection(.enabled)
                    }

                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
                }
            }
        }
    }
}
