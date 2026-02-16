import SwiftUI

/// Syntax-highlighted code block view
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

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
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
}
