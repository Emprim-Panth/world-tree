import SwiftUI
import WebKit

// MARK: - Diagram Panel

/// Right-side panel that shows the active Mermaid diagram full-size and centered.
/// Appears/disappears via AppState.activeMermaidCode.
struct DiagramPanelView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .font(.caption)
                    .foregroundStyle(.cyan)
                Text("Diagram")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        appState.activeMermaidCode = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close diagram panel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if let code = appState.activeMermaidCode {
                MermaidWebPanelView(code: code)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Mermaid Web Panel

/// Full-frame WKWebView that renders a Mermaid diagram centered and scaled to fit.
/// No zoom controls — diagram fills the panel at natural aspect ratio.
struct MermaidWebPanelView: NSViewRepresentable {
    let code: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Transparent — let body background show through
        webView.setValue(false, forKey: "drawsBackground")
        webView.layer?.backgroundColor = NSColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1).cgColor
        context.coordinator.currentCode = code
        webView.loadHTMLString(buildHTML(), baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.currentCode != code else { return }
        context.coordinator.currentCode = code
        webView.loadHTMLString(buildHTML(), baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var currentCode = ""
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("window.scrollTo(0,0)") { _, _ in }
        }
    }

    private func buildHTML() -> String {
        let mermaidJS = loadResource("mermaid.min", type: "js") ?? ""
        let b64 = Data(code.utf8).base64EncodedString()
        return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body {
                width: 100%; height: 100%;
                background: #0d1117;
                overflow: hidden;
            }
            body {
                display: flex;
                align-items: center;
                justify-content: center;
                padding: 24px;
            }
            #diagram {
                display: flex;
                align-items: center;
                justify-content: center;
                width: 100%;
                height: 100%;
            }
            #diagram svg {
                display: block;
                max-width: 100%;
                max-height: 100%;
                width: auto;
                height: auto;
            }
            #error {
                color: #f85149;
                font-family: -apple-system, sans-serif;
                font-size: 12px;
                padding: 12px;
            }
            </style>
            <script>\(mermaidJS)</script>
            </head>
            <body>
            <div id="diagram"></div>
            <script>
            (async function() {
                const encoded = '\(b64)';
                const code = decodeURIComponent(escape(atob(encoded)));
                mermaid.initialize({
                    startOnLoad: false,
                    theme: 'dark',
                    themeVariables: {
                        background: '#0d1117',
                        primaryColor: '#58a6ff',
                        primaryTextColor: '#e6edf3',
                        lineColor: '#30363d',
                        secondaryColor: '#161b22',
                        tertiaryColor: '#21262d'
                    }
                });
                try {
                    const { svg } = await mermaid.render('diagram-panel-svg', code);
                    document.getElementById('diagram').innerHTML = svg;
                    const svgEl = document.querySelector('#diagram svg');
                    if (svgEl) {
                        svgEl.removeAttribute('width');
                        svgEl.removeAttribute('height');
                    }
                } catch(e) {
                    document.getElementById('diagram').innerHTML =
                        '<div id="error">Render error: ' + e.message + '</div>';
                }
            })();
            </script>
            </body>
            </html>
            """
    }

    private func loadResource(_ name: String, type: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: type),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return content
    }
}
