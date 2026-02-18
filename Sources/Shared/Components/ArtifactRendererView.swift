import SwiftUI
import WebKit

// MARK: - Weak script message handler proxy
// WKUserContentController retains its handlers strongly, which would create a
// retain cycle (webView → controller → coordinator → binding → SwiftUI).
// This proxy breaks the cycle by holding the delegate weakly.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        delegate?.userContentController(controller, didReceive: message)
    }
}

// MARK: - Artifact Renderer Mode

enum ArtifactRenderMode {
    case syntax(language: String?)   // Syntax-highlighted source code
    case mermaid                     // Mermaid diagram
    case html                        // Raw HTML render
    case svg                         // SVG graphic
    case graph                       // Interactive vis-network node graph (JSON input)
}

// MARK: - Artifact Renderer View

/// WKWebView-based renderer for code syntax highlighting and rich content.
/// Uses bundled highlight.js and mermaid.js — no network required.
struct ArtifactRendererView: NSViewRepresentable {
    let content: String
    let mode: ArtifactRenderMode
    /// Estimated height of the rendered content (used for frame sizing).
    @Binding var renderedHeight: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Register JS→Swift message handler for graph height reporting
        if case .graph = mode {
            config.userContentController.add(
                WeakScriptMessageHandler(context.coordinator),
                name: "graphHeight"
            )
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(true, forKey: "drawsBackground")
        webView.layer?.backgroundColor = NSColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1).cgColor
        webView.isHidden = true  // show once loaded
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Guard against reload loop: SwiftUI calls updateNSView whenever any
        // @State changes (including renderedHeight), which would re-trigger
        // the physics simulation on every height update. Load once only.
        guard !context.coordinator.hasLoaded else { return }
        context.coordinator.hasLoaded = true
        webView.loadHTMLString(buildHTML(), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(renderedHeight: $renderedHeight)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var renderedHeight: CGFloat
        /// Guards against updateNSView reload loop — HTML is loaded exactly once.
        var hasLoaded = false

        init(renderedHeight: Binding<CGFloat>) {
            _renderedHeight = renderedHeight
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Show view and measure content height.
            // For mermaid/svg we poll briefly to let the renderer finish drawing
            // before measuring — mermaid renders async after DOMContentLoaded.
            // For graphs, the stabilized event posts a precise height via messageHandler,
            // but hierarchical layouts have physics disabled so stabilized never fires —
            // we show the view here and fall back to the container height.
            webView.isHidden = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                webView.evaluateJavaScript("document.getElementById('graph') ? document.getElementById('graph').offsetHeight || document.body.scrollHeight : document.body.scrollHeight") { result, _ in
                    if let height = result as? CGFloat, height > 0 {
                        DispatchQueue.main.async {
                            self.renderedHeight = max(height, 80)
                        }
                    }
                }
            }
        }

        /// Receives precise height from vis-network's stabilized event.
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "graphHeight" {
                let height: CGFloat = (message.body as? Double).map { CGFloat($0) } ?? 400
                DispatchQueue.main.async {
                    self.renderedHeight = max(height, 200)
                }
            }
        }
    }

    // MARK: - HTML Generation

    private func buildHTML() -> String {
        let highlightJS = loadResource("highlight.min", type: "js") ?? ""
        let highlightCSS = loadResource("highlight-github-dark.min", type: "css") ?? ""
        let escapedContent = escapeHTML(content)

        switch mode {
        case .syntax(let language):
            let langClass = language.map { "language-\($0)" } ?? ""
            return """
                <!DOCTYPE html>
                <html>
                <head>
                <meta charset="utf-8">
                <style>
                \(highlightCSS)
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                    background: #0d1117;
                    font-family: 'SF Mono', 'Fira Code', 'Menlo', monospace;
                    font-size: 12px;
                    line-height: 1.5;
                    padding: 10px;
                    -webkit-user-select: text;
                    user-select: text;
                    overflow-x: auto;
                    overflow-y: hidden;
                }
                pre { margin: 0; white-space: pre; }
                code { font-size: 12px; }
                .hljs { background: transparent; padding: 0; }
                </style>
                <script>\(highlightJS)</script>
                </head>
                <body>
                <pre><code class="\(langClass)">\(escapedContent)</code></pre>
                <script>hljs.highlightAll();</script>
                </body>
                </html>
                """

        case .mermaid:
            let mermaidJS = loadResource("mermaid.min", type: "js") ?? ""
            return """
                <!DOCTYPE html>
                <html>
                <head>
                <meta charset="utf-8">
                <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                    background: #0d1117;
                    display: flex;
                    justify-content: center;
                    align-items: flex-start;
                    padding: 16px;
                    overflow-x: auto;
                    overflow-y: hidden;
                }
                .mermaid { max-width: 100%; }
                svg { max-width: 100%; height: auto; }
                </style>
                <script>\(mermaidJS)</script>
                </head>
                <body>
                <div class="mermaid">\(escapedContent)</div>
                <script>
                mermaid.initialize({
                    startOnLoad: true,
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
                </script>
                </body>
                </html>
                """

        case .html:
            return """
                <!DOCTYPE html>
                <html>
                <head>
                <meta charset="utf-8">
                <style>
                body {
                    background: #0d1117;
                    color: #e6edf3;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-size: 13px;
                    padding: 12px;
                    -webkit-user-select: text;
                    user-select: text;
                }
                </style>
                </head>
                <body>
                \(content)
                </body>
                </html>
                """

        case .svg:
            return """
                <!DOCTYPE html>
                <html>
                <head>
                <meta charset="utf-8">
                <style>
                * { margin: 0; padding: 0; }
                body {
                    background: #0d1117;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    padding: 12px;
                }
                svg { max-width: 100%; height: auto; }
                </style>
                </head>
                <body>
                \(content)
                </body>
                </html>
                """

        case .graph:
            let visJS = loadResource("vis-network.min", type: "js") ?? ""
            // Escape characters that would break JS template literal interpolation
            let safeJSON = content
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            return """
                <!DOCTYPE html>
                <html>
                <head>
                <meta charset="utf-8">
                <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body { background: #0d1117; overflow: hidden; font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; }
                #graph { width: 100%; height: 420px; background: #0d1117; }
                #error { display: none; color: #f85149; font-family: 'SF Mono', monospace; font-size: 11px; padding: 12px; white-space: pre-wrap; }
                .vis-tooltip {
                    background: #161b22 !important; border: 1px solid #30363d !important;
                    color: #e6edf3 !important; font-family: -apple-system, sans-serif !important;
                    font-size: 12px !important; border-radius: 6px !important;
                    padding: 6px 10px !important; box-shadow: 0 4px 12px rgba(0,0,0,0.5) !important;
                }
                </style>
                <script>\(visJS)</script>
                </head>
                <body>
                <div id="graph"></div>
                <div id="error"></div>
                <script>
                (function() {
                    var PALETTE = {
                        frontend: { background:'#1f4068', border:'#79c0ff', highlight:{ background:'#2d5f9a', border:'#a5d6ff' } },
                        backend:  { background:'#1a3a1a', border:'#56d364', highlight:{ background:'#2a5a2a', border:'#7ee787' } },
                        storage:  { background:'#3a1f1f', border:'#ff9492', highlight:{ background:'#5a2a2a', border:'#ffadab' } },
                        system:   { background:'#2d1f3d', border:'#d2a8ff', highlight:{ background:'#3d2a55', border:'#e2bfff' } },
                        warning:  { background:'#3a3300', border:'#f0c860', highlight:{ background:'#504500', border:'#ffd980' } },
                        api:      { background:'#102040', border:'#79c0ff', highlight:{ background:'#1e3050', border:'#a5d6ff' } },
                        ui:       { background:'#0d2137', border:'#58a6ff', highlight:{ background:'#1a3a5e', border:'#79c0ff' } },
                        default:  { background:'#2d333b', border:'#adbac7', highlight:{ background:'#3d444d', border:'#cdd9e5' } }
                    };

                    function groupColor(g) { return PALETTE[g] || PALETTE.default; }

                    var spec;
                    try { spec = JSON.parse(`\(safeJSON)`); }
                    catch(e) {
                        var errEl = document.getElementById('error');
                        errEl.style.display = 'block';
                        errEl.textContent = 'Graph JSON error:\\n' + e.message;
                        return;
                    }

                    var rawNodes = spec.nodes || [];
                    var rawEdges = spec.edges || [];
                    var opts = spec.options || {};

                    var nodes = new vis.DataSet(rawNodes.map(function(n) {
                        // If spec defines groups and this node's group is in spec.groups,
                        // let vis-network apply the group style (don't set color manually).
                        var useGroupStyle = spec.groups && n.group && spec.groups[n.group];
                        return {
                            id: n.id,
                            label: n.label || String(n.id),
                            group: n.group || undefined,
                            shape: n.shape || 'ellipse',
                            size: n.size || 20,
                            title: n.title || undefined,
                            color: (n.color && n.color !== 'auto')
                                ? { background: n.color, border: n.color, highlight: { background: n.color, border: '#fff' } }
                                : useGroupStyle ? undefined : groupColor(n.group),
                            font: { color: '#ffffff', size: 13, face: '-apple-system, sans-serif', bold: { color: '#ffffff' } }
                        };
                    }));

                    var edges = new vis.DataSet(rawEdges.map(function(e, i) {
                        return {
                            id: i, from: e.from, to: e.to,
                            label: e.label || undefined,
                            arrows: e.arrows !== undefined ? e.arrows : 'to',
                            dashes: e.dashes || false,
                            title: e.title || undefined,
                            color: { color: '#6e7681', highlight: '#79c0ff', hover: '#79c0ff' },
                            font: { color: '#cdd9e5', size: 11, align: 'middle', background: '#0d1117', strokeWidth: 0 },
                            smooth: { type: 'continuous' }
                        };
                    }));

                    // Build vis-network groups from spec.groups (if provided)
                    var visGroups = {};
                    if (spec.groups) {
                        Object.keys(spec.groups).forEach(function(g) {
                            var grp = spec.groups[g];
                            visGroups[g] = {
                                color: grp.color || PALETTE[g] || PALETTE.default,
                                font: { color: '#ffffff', size: 13, face: '-apple-system, sans-serif' }
                            };
                        });
                    }

                    var isHierarchical = opts.layout === 'hierarchical';
                    var networkOpts = {
                        groups: visGroups,
                        nodes: { borderWidth: 1.5, borderWidthSelected: 2.5,
                            shadow: { enabled: true, color: 'rgba(0,0,0,0.4)', size: 8, x: 2, y: 2 } },
                        edges: { width: 1.5, selectionWidth: 2.5 },
                        layout: isHierarchical
                            ? { hierarchical: { enabled: true, direction: opts.direction || 'UD',
                                sortMethod: 'directed', levelSeparation: 100, nodeSpacing: 120 } }
                            : { randomSeed: 42 },
                        physics: isHierarchical
                            ? { enabled: false }
                            : { enabled: true,
                                barnesHut: { gravitationalConstant: -4000, springLength: 120, damping: 0.2 },
                                stabilization: { iterations: 400, fit: true } },
                        interaction: { hover: true, tooltipDelay: 200, zoomView: true,
                            dragView: true, selectConnectedEdges: true,
                            navigationButtons: false, keyboard: false },
                        configure: { enabled: false }
                    };

                    var container = document.getElementById('graph');
                    if (opts.height) container.style.height = opts.height + 'px';

                    var network = new vis.Network(container, { nodes: nodes, edges: edges }, networkOpts);

                    // Click-to-highlight: dim unconnected nodes/edges
                    var origColors = {};
                    nodes.forEach(function(n) { origColors[n.id] = n.color; });

                    network.on('click', function(params) {
                        if (params.nodes.length === 0) {
                            nodes.forEach(function(n) { nodes.update({ id: n.id, color: origColors[n.id], opacity: 1 }); });
                            edges.forEach(function(e) { edges.update({ id: e.id, color: { color: '#30363d', highlight: '#58a6ff' }, opacity: 1 }); });
                            return;
                        }
                        var sel = params.nodes[0];
                        var connected = network.getConnectedNodes(sel);
                        connected.push(sel);
                        var connSet = {};
                        connected.forEach(function(id) { connSet[id] = true; });
                        var connEdges = {};
                        network.getConnectedEdges(sel).forEach(function(id) { connEdges[id] = true; });

                        nodes.forEach(function(n) { nodes.update({ id: n.id, opacity: connSet[n.id] ? 1 : 0.25 }); });
                        edges.forEach(function(e) { edges.update({ id: e.id, opacity: connEdges[e.id] ? 1 : 0.15 }); });
                    });

                    // Report precise height to Swift once layout is complete.
                    // Physics-based layouts: fire on 'stabilized'.
                    // Hierarchical layouts (physics disabled): fire on first 'afterDrawing'.
                    function reportHeight() {
                        network.fit({ animation: { duration: 300, easingFunction: 'easeInOutQuad' } });
                        setTimeout(function() {
                            var h = container.offsetHeight || 420;
                            try { window.webkit.messageHandlers.graphHeight.postMessage(h); } catch(e) {}
                        }, 350);
                    }

                    if (isHierarchical) {
                        var fired = false;
                        network.on('afterDrawing', function() {
                            if (!fired) { fired = true; reportHeight(); }
                        });
                    } else {
                        network.on('stabilized', function() { reportHeight(); });
                    }
                })();
                </script>
                </body>
                </html>
                """
        }
    }

    // MARK: - Helpers

    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func loadResource(_ name: String, type: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: type),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return content
    }
}
