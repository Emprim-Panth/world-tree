import SwiftUI

/// Syntax-highlighted code block view.
/// Uses ArtifactRendererView (WKWebView + highlight.js) for renderable content
/// and visible code blocks within the WebView pool cap.
/// Falls back to a lightweight NSFont-based text display when the pool is full.
struct CodeBlockView: View {
    let code: String
    let language: String?

    @Environment(\.conversationHPad) private var conversationHPad

    @State private var isHoveringCode = false
    @State private var justCopied = false
    @State private var syntaxHeight: CGFloat = 80
    @State private var previewHeight: CGFloat = 500
    @State private var isVisible = false

    /// Unique ID for pool registration
    @State private var poolId = UUID().uuidString

    // Mermaid/HTML/SVG default to preview-on; source code defaults to source-on
    @State private var showPreview: Bool

    init(code: String, language: String?) {
        self.code = code
        self.language = language
        let lang = language?.lowercased() ?? ""
        _showPreview = State(initialValue: ["mermaid", "html", "htm", "svg", "graph"].contains(lang))
    }

    /// Whether to use a full WKWebView or the lightweight fallback.
    /// Renderable content (mermaid, html, svg) always gets a WKWebView.
    /// Plain code only gets a WKWebView if there's pool capacity.
    private var useWebView: Bool {
        if isRenderable { return true }
        return isVisible && WebViewPool.shared.hasCapacity
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

                // Copy button — always in layout to prevent shift, opacity-controlled
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation(.easeInOut(duration: 0.15)) { justCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.easeInOut(duration: 0.15)) { justCopied = false }
                    }
                } label: {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(justCopied ? .green : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .padding(.vertical, 2)
                .opacity(isHoveringCode || justCopied ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isHoveringCode)
            }
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))

            // ── Syntax-highlighted source ─────────────────────────────────
            if !showPreview {
                if useWebView {
                    ArtifactRendererView(
                        content: code,
                        mode: .syntax(language: language),
                        renderedHeight: $syntaxHeight
                    )
                    .frame(height: syntaxHeight)
                    .transition(.opacity)
                } else {
                    // Lightweight fallback — plain monospace text with no WKWebView
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxHeight: 400)
                    .transition(.opacity)
                }
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
                // Mermaid breaks out of the conversation's horizontal padding
                // so it spans the full detail pane width — left edge to right edge.
                .padding(.horizontal, { if case .mermaid = renderMode { return -conversationHPad }; return 0 }())
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
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            WebViewPool.shared.release(id: poolId)
        }
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
