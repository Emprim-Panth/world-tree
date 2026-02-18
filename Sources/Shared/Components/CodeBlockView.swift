import SwiftUI

/// Syntax-highlighted code block view.
/// Uses ArtifactRendererView (WKWebView + highlight.js) for all languages.
/// Mermaid, HTML, and SVG blocks get an additional "Preview" toggle.
struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var isHoveringCode = false
    @State private var syntaxHeight: CGFloat = 80
    @State private var previewHeight: CGFloat = 300

    // Mermaid/HTML/SVG default to preview-on; source code defaults to source-on
    @State private var showPreview: Bool

    init(code: String, language: String?) {
        self.code = code
        self.language = language
        let lang = language?.lowercased() ?? ""
        _showPreview = State(initialValue: ["mermaid", "html", "htm", "svg", "graph"].contains(lang))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header bar ────────────────────────────────────────────────
            HStack(spacing: 6) {
                if let language {
                    Text(language)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                }

                Spacer()

                // Preview toggle — only for renderable content
                if isRenderable {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showPreview.toggle()
                        }
                    } label: {
                        Label(showPreview ? "Source" : "Preview",
                              systemImage: showPreview ? "chevron.left.slash.chevron.right" : "play.rectangle")
                            .font(.caption2)
                            .foregroundStyle(showPreview ? Color.secondary : Color.cyan)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }

                // Copy button (shown on hover)
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
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))

            // ── Syntax-highlighted source ─────────────────────────────────
            if !showPreview {
                ArtifactRendererView(
                    content: code,
                    mode: .syntax(language: language),
                    renderedHeight: $syntaxHeight
                )
                .frame(height: syntaxHeight)
                .transition(.opacity)
            }

            // ── Preview (mermaid / html / svg) ────────────────────────────
            if showPreview, let renderMode = previewRenderMode {
                Divider()

                ArtifactRendererView(
                    content: code,
                    mode: renderMode,
                    renderedHeight: $previewHeight
                )
                .frame(height: previewHeight)
                .transition(.opacity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .cornerRadius(6)
        .onHover { isHoveringCode = $0 }
    }

    // MARK: - Renderable Language Detection

    /// Languages that can be rendered visually (not just highlighted)
    private var isRenderable: Bool {
        guard let lang = language?.lowercased() else { return false }
        return ["mermaid", "html", "htm", "svg", "graph"].contains(lang)
    }

    private var previewRenderMode: ArtifactRenderMode? {
        switch language?.lowercased() {
        case "mermaid": return .mermaid
        case "html", "htm": return .html
        case "svg": return .svg
        case "graph": return .graph
        default: return nil
        }
    }
}
