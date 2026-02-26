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

// MARK: - Shared Notifications

extension Notification.Name {
    static let choiceSelected = Notification.Name("choiceSelected")
}

// MARK: - Artifact Renderer Mode

enum ArtifactRenderMode {
    case syntax(language: String?)   // Syntax-highlighted source code
    case mermaid                     // Mermaid diagram
    case html                        // Raw HTML render
    case svg                         // SVG graphic
    case graph                       // Interactive vis-network node graph (JSON input)
    case choiceTree                  // Interactive decision tree — click to choose, drag to reorganize
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
        let config = WebViewPool.shared.makeConfiguration()

        // Register JS→Swift message handlers
        if case .mermaid = mode {
            config.userContentController.add(
                WeakScriptMessageHandler(context.coordinator),
                name: "mermaidHeight"
            )
        }
        if case .graph = mode {
            config.userContentController.add(
                WeakScriptMessageHandler(context.coordinator),
                name: "graphHeight"
            )
        }
        if case .choiceTree = mode {
            config.userContentController.add(
                WeakScriptMessageHandler(context.coordinator),
                name: "graphHeight"
            )
            config.userContentController.add(
                WeakScriptMessageHandler(context.coordinator),
                name: "choiceSelected"
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
        let skipGeneric: Bool
        if case .mermaid = mode { skipGeneric = true } else { skipGeneric = false }
        return Coordinator(renderedHeight: $renderedHeight, skipGenericHeightQuery: skipGeneric)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var renderedHeight: CGFloat
        /// Guards against updateNSView reload loop — HTML is loaded exactly once.
        var hasLoaded = false
        /// When true, skip the generic scrollHeight probe — the mode uses a dedicated JS message instead.
        let skipGenericHeightQuery: Bool

        init(renderedHeight: Binding<CGFloat>, skipGenericHeightQuery: Bool = false) {
            _renderedHeight = renderedHeight
            self.skipGenericHeightQuery = skipGenericHeightQuery
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.isHidden = false
            if skipGenericHeightQuery {
                // Mermaid renders async — poll body.scrollHeight until content appears.
                pollHeight(webView: webView, attempt: 0)
            } else {
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
        }

        func pollHeight(webView: WKWebView, attempt: Int) {
            let delay: TimeInterval = attempt == 0 ? 0.4 : 0.3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                webView.evaluateJavaScript("document.body.scrollHeight") { result, _ in
                    let h = (result as? Double).map { CGFloat($0) } ?? 0
                    if h > 80 {
                        DispatchQueue.main.async {
                            self.renderedHeight = min(max(h, 450), 700)
                            // Snap to top so toolbar is always the first thing visible.
                            webView.evaluateJavaScript("window.scrollTo(0,0)") { _, _ in }
                        }
                    } else if attempt < 6 {
                        self.pollHeight(webView: webView, attempt: attempt + 1)
                    }
                }
            }
        }

        /// Receives messages from vis-network: height reports and choice selections.
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "mermaidHeight" {
                let height: CGFloat = (message.body as? Double).map { CGFloat($0) } ?? 450
                DispatchQueue.main.async {
                    self.renderedHeight = max(height, 200)
                }
            } else if message.name == "graphHeight" {
                let height: CGFloat = (message.body as? Double).map { CGFloat($0) } ?? 400
                DispatchQueue.main.async {
                    self.renderedHeight = max(height, 200)
                }
            } else if message.name == "choiceSelected" {
                guard let label = message.body as? String, !label.isEmpty else { return }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .choiceSelected,
                        object: nil,
                        userInfo: ["choice": label]
                    )
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
            // Base64-encode so the HTML parser never mangles -->, &, <!-- sequences.
            let b64 = Data(content.utf8).base64EncodedString()
            return """
                <!DOCTYPE html>
                <html>
                <head>
                <meta charset="utf-8">
                <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body { width: 100%; height: 500px; overflow: hidden; background: #0d1117; }
                #stage {
                    width: 100%; height: 100%;
                    position: relative; overflow: hidden;
                    cursor: grab;
                }
                #stage.dragging { cursor: grabbing; }
                #mover {
                    position: absolute; top: 0; left: 0;
                    transform-origin: 0 0;
                }
                #mover svg { display: block; overflow: visible; }
                .node-lit rect, .node-lit polygon,
                .node-lit circle, .node-lit ellipse {
                    fill: #1f3d6e !important;
                    stroke: #4fc3f7 !important;
                    stroke-width: 2.5px !important;
                }
                .edge-lit path { stroke: #4fc3f7 !important; stroke-width: 2.5px !important; }
                .edge-lit marker path { fill: #4fc3f7 !important; }
                g.node { cursor: pointer; }
                #hint {
                    position: absolute; bottom: 8px; right: 10px;
                    color: rgba(255,255,255,0.2);
                    font: 10px -apple-system, sans-serif;
                    pointer-events: none; user-select: none;
                }
                </style>
                <script>\(mermaidJS)</script>
                </head>
                <body>
                <div id="stage">
                  <div id="mover"></div>
                  <div id="hint">scroll·zoom &nbsp; drag·pan &nbsp; click·path &nbsp; dbl·reset</div>
                </div>
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

                    let svgText;
                    try {
                        const result = await mermaid.render('mermaid-svg', code);
                        svgText = result.svg;
                    } catch(e) {
                        document.body.innerHTML = '<div style="color:#f85149;padding:20px;font:13px -apple-system,sans-serif">Render error: ' + e.message + '</div>';
                        return;
                    }

                    const mover = document.getElementById('mover');
                    mover.innerHTML = svgText;
                    const svgEl = mover.querySelector('svg');
                    svgEl.style.maxWidth = 'none';

                    // Pin SVG to its natural viewBox pixel size so transforms work correctly
                    const vb = svgEl.viewBox.baseVal;
                    const svgW = (vb && vb.width > 0) ? vb.width  : (parseFloat(svgEl.getAttribute('width'))  || 800);
                    const svgH = (vb && vb.height > 0) ? vb.height : (parseFloat(svgEl.getAttribute('height')) || 500);
                    svgEl.setAttribute('width',  svgW);
                    svgEl.setAttribute('height', svgH);

                    // Fit-to-stage with 8% margin. These become the zoom bounds.
                    const stage = document.getElementById('stage');
                    const sw = stage.clientWidth, sh = stage.clientHeight;
                    const FIT = Math.min(sw / svgW, sh / svgH) * 0.92;
                    const MIN_SCALE = FIT * 0.82; // can't zoom out past ~fit
                    const MAX_SCALE = FIT * 6.0;  // max ~6x zoom in
                    let scale = FIT;
                    let tx = (sw - svgW * scale) / 2;
                    let ty = (sh - svgH * scale) / 2;

                    function clampTx() {
                        // Keep at least 80px of graph visible on each side
                        const vis = 80;
                        tx = Math.max(vis - svgW * scale, Math.min(sw - vis, tx));
                        ty = Math.max(vis - svgH * scale, Math.min(sh - vis, ty));
                    }
                    function applyXform() {
                        mover.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')';
                    }
                    applyXform();

                    // Pan
                    let drag = false, ox = 0, oy = 0;
                    stage.addEventListener('mousedown', function(e) {
                        if (e.target.closest('g.node')) return;
                        drag = true; ox = e.clientX; oy = e.clientY;
                        stage.classList.add('dragging'); e.preventDefault();
                    });
                    document.addEventListener('mousemove', function(e) {
                        if (!drag) return;
                        tx += e.clientX - ox; ty += e.clientY - oy;
                        ox = e.clientX; oy = e.clientY; clampTx(); applyXform();
                    });
                    document.addEventListener('mouseup', function() {
                        drag = false; stage.classList.remove('dragging');
                    });

                    // Zoom toward cursor — clamped to [MIN_SCALE, MAX_SCALE]
                    stage.addEventListener('wheel', function(e) {
                        e.preventDefault();
                        const f = e.deltaY > 0 ? 0.88 : 1.14;
                        const newScale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, scale * f));
                        if (newScale === scale) return;
                        const r = stage.getBoundingClientRect();
                        const cx = e.clientX - r.left, cy = e.clientY - r.top;
                        tx = cx - (newScale / scale) * (cx - tx);
                        ty = cy - (newScale / scale) * (cy - ty);
                        scale = newScale; clampTx(); applyXform();
                    }, { passive: false });

                    // Double-click: reset to fit
                    stage.addEventListener('dblclick', function() {
                        scale = FIT;
                        tx = (sw - svgW * scale) / 2; ty = (sh - svgH * scale) / 2;
                        applyXform(); clearLit();
                    });

                    // --- Graph structure parsing ---
                    // Splits each line on --> and extracts source/target word IDs.
                    // Handles all mermaid node shapes: [label] ([label]) {label} ((label))
                    // Supports multiple parents per node (diamond convergence).
                    const parentsOf = {}; // nodeId -> [parentId, ...]
                    const edgeList  = []; // [{from, to}]
                    code.split('\\n').forEach(function(line) {
                        line = line.replace(/%%.*$/, '').trim();
                        if (line.indexOf('-->') === -1) return;
                        const parts = line.split('-->');
                        if (parts.length < 2) return;
                        const srcM = parts[0].trim().match(/^(\\w+)/);
                        if (!srcM) return;
                        const src = srcM[1];
                        // Strip optional edge label |...|
                        const rhs = parts[parts.length - 1].replace(/^\\s*\\|[^|]*\\|\\s*/, '');
                        const dstM = rhs.match(/^(\\w+)/);
                        if (!dstM) return;
                        const dst = dstM[1];
                        if (src === dst) return;
                        if (!parentsOf[dst]) parentsOf[dst] = [];
                        if (parentsOf[dst].indexOf(src) === -1) parentsOf[dst].push(src);
                        edgeList.push({ from: src, to: dst });
                    });

                    // BFS backward from clicked node — returns ALL paths to any root.
                    // Handles both linear chains and diamond convergence correctly.
                    function allPathsToRoot(nodeId) {
                        var results = [];
                        function dfs(id, path) {
                            var parents = parentsOf[id] || [];
                            if (parents.length === 0) { results.push(path.slice().reverse()); return; }
                            parents.forEach(function(p) { dfs(p, path.concat(p)); });
                        }
                        dfs(nodeId, [nodeId]);
                        return results;
                    }

                    function clearLit() {
                        svgEl.querySelectorAll('.node-lit,.edge-lit').forEach(function(el) {
                            el.classList.remove('node-lit', 'edge-lit');
                        });
                    }

                    function highlightEdge(a, b) {
                        // Try both ID formats mermaid v10 may produce
                        ['L-'+a+'-'+b, 'L_'+a+'_'+b, 'L-'+a+'-'+b+'-0'].forEach(function(pat) {
                            svgEl.querySelectorAll('[id*="'+pat+'"]').forEach(function(el) {
                                el.classList.add('edge-lit');
                            });
                        });
                        // Also try class-based selector
                        svgEl.querySelectorAll('.flowchart-link.'+a+'.'+b).forEach(function(el) {
                            el.classList.add('edge-lit');
                        });
                    }

                    // Click node → highlight every path from root to that node
                    svgEl.querySelectorAll('g.node').forEach(function(g) {
                        g.addEventListener('click', function(e) {
                            e.stopPropagation(); clearLit();
                            const m = g.id.match(/flowchart-(\\w+)-/);
                            if (!m) return;
                            const paths = allPathsToRoot(m[1]);
                            if (paths.length === 0) paths.push([m[1]]);
                            const litNodes = {};
                            paths.forEach(function(path) {
                                path.forEach(function(id) { litNodes[id] = true; });
                                for (var i = 0; i < path.length - 1; i++) {
                                    highlightEdge(path[i], path[i+1]);
                                }
                            });
                            Object.keys(litNodes).forEach(function(id) {
                                svgEl.querySelectorAll('g[id*="flowchart-'+id+'-"]').forEach(function(el) {
                                    el.classList.add('node-lit');
                                });
                            });
                        });
                    });

                    // Report fixed height to Swift
                    try { window.webkit.messageHandlers.mermaidHeight.postMessage(500); } catch(e) {}
                })();
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

        case .choiceTree:
            let visJS = loadResource("vis-network.min", type: "js") ?? ""
            let safeContent = content
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "\\n")
            return """
                <!DOCTYPE html>
                <html>
                <head>
                <meta charset="utf-8">
                <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body { background: #0d1117; overflow: hidden; position: relative;
                       font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; }
                #tree { width: 100%; background: #0d1117; }
                #edit-overlay {
                    display: none; position: absolute; z-index: 100;
                    background: #161b22; border: 1.5px solid #58a6ff;
                    border-radius: 8px; padding: 8px 10px;
                    box-shadow: 0 4px 16px rgba(0,0,0,0.6);
                }
                #edit-input {
                    background: transparent; border: none; outline: none;
                    color: #e6edf3; font-family: -apple-system, sans-serif;
                    font-size: 13px; width: 220px;
                }
                .vis-tooltip {
                    background: #161b22 !important; border: 1px solid #30363d !important;
                    color: #e6edf3 !important; border-radius: 6px !important;
                    font-size: 12px !important; padding: 4px 8px !important;
                }
                </style>
                <script>\(visJS)</script>
                </head>
                <body>
                <div id="tree"></div>
                <div id="edit-overlay"><input id="edit-input" type="text" /></div>
                <script>
                (function() {
                    function wrapLabel(text, max) {
                        if (!text || text.length <= max) return text;
                        var words = text.split(' '), lines = [], cur = '';
                        for (var i = 0; i < words.length; i++) {
                            var w = words[i];
                            var candidate = cur ? cur + ' ' + w : w;
                            if (candidate.length > max && cur) { lines.push(cur); cur = w; }
                            else { cur = candidate; }
                        }
                        if (cur) lines.push(cur);
                        return lines.join('\\n');
                    }

                    var raw = "\(safeContent)";
                    var lines = raw.split('\\n');
                    var question = '', options = [];
                    for (var i = 0; i < lines.length; i++) {
                        var t = lines[i].trim();
                        if (t.indexOf('- ') === 0) {
                            options.push(t.slice(2).trim());
                        } else if (t && !question) {
                            question = t;
                        }
                    }
                    if (!options.length) return;

                    var nodeData = [{
                        id: 0, label: wrapLabel(question || 'Choose:', 34), shape: 'box', level: 0,
                        color: { background: '#0d2137', border: '#58a6ff',
                                 highlight: { background: '#1a3a5e', border: '#79c0ff' } },
                        font: { color: '#e6edf3', size: 13, face: '-apple-system,sans-serif',
                                bold: { color: '#e6edf3', size: 13 } },
                        margin: { top: 10, bottom: 10, left: 14, right: 14 },
                        widthConstraint: { maximum: 300 }, chosen: false
                    }];
                    for (var i = 0; i < options.length; i++) {
                        nodeData.push({
                            id: i + 1, label: wrapLabel(options[i], 30), shape: 'box', level: 1,
                            color: { background: '#0d1f17', border: '#3fb950',
                                     highlight: { background: '#1a3a28', border: '#56d364' } },
                            font: { color: '#e6edf3', size: 13, face: '-apple-system,sans-serif' },
                            margin: { top: 10, bottom: 10, left: 14, right: 14 },
                            widthConstraint: { maximum: 260 }, chosen: false
                        });
                    }
                    var edgeData = options.map(function(_, i) {
                        return { id: i, from: 0, to: i + 1,
                            arrows: { to: { enabled: true, scaleFactor: 0.7 } },
                            color: { color: '#30363d', highlight: '#58a6ff', hover: '#58a6ff' },
                            smooth: { type: 'cubicBezier', forceDirection: 'vertical', roundness: 0.4 } };
                    });

                    var nodes = new vis.DataSet(nodeData);
                    var edges = new vis.DataSet(edgeData);
                    var h = Math.max(240, 160 + options.length * 100);
                    var container = document.getElementById('tree');
                    container.style.height = h + 'px';

                    var network = new vis.Network(container, { nodes: nodes, edges: edges }, {
                        layout: { hierarchical: {
                            enabled: true, direction: 'UD', sortMethod: 'directed',
                            levelSeparation: 120, nodeSpacing: 160,
                            treeSpacing: 80, blockShifting: true,
                            edgeMinimization: true, parentCentralization: true
                        }},
                        physics: { enabled: false },
                        interaction: { hover: true, dragNodes: true, dragView: true,
                                       zoomView: true, selectConnectedEdges: false,
                                       navigationButtons: false, keyboard: false },
                        nodes: { borderWidth: 1.5, borderWidthSelected: 2.5 },
                        edges: { width: 1.5 },
                        configure: { enabled: false }
                    });

                    // Click an option node to select it — locked after first choice
                    var locked = false;
                    network.on('click', function(params) {
                        if (params.nodes.length === 0) { hideEdit(); return; }
                        if (locked) return;
                        var id = params.nodes[0];
                        if (id === 0) return;
                        locked = true;
                        for (var i = 1; i <= options.length; i++) {
                            if (i === id) {
                                nodes.update({ id: i,
                                    color: { background: '#1a3a28', border: '#7ee787',
                                             highlight: { background: '#2a5a38', border: '#7ee787' } },
                                    font: { color: '#7ee787', size: 13, face: '-apple-system,sans-serif',
                                            bold: { color: '#7ee787', size: 13 } }
                                });
                            } else {
                                nodes.update({ id: i, opacity: 0.25,
                                    color: { background: '#0d1117', border: '#21262d',
                                             highlight: { background: '#0d1117', border: '#21262d' } },
                                    font: { color: '#484f58', size: 13, face: '-apple-system,sans-serif' }
                                });
                            }
                        }
                        edges.forEach(function(e) {
                            if (e.to === id) {
                                edges.update({ id: e.id, color: { color: '#7ee787', highlight: '#7ee787' }, width: 2 });
                            } else {
                                edges.update({ id: e.id, opacity: 0.15, color: { color: '#21262d', highlight: '#21262d' } });
                            }
                        });
                        var label = options[id - 1];
                        try { window.webkit.messageHandlers.choiceSelected.postMessage(label); } catch(e) {}
                    });

                    // Double-click any node to edit its label inline
                    var editNodeId = -1;
                    network.on('doubleClick', function(params) {
                        if (params.nodes.length === 0) { hideEdit(); return; }
                        var id = params.nodes[0];
                        editNodeId = id;
                        var pos = network.canvasToDOM(network.getPositions([id])[id]);
                        var overlay = document.getElementById('edit-overlay');
                        var inp = document.getElementById('edit-input');
                        inp.value = id === 0 ? question : options[id - 1];
                        overlay.style.display = 'block';
                        overlay.style.left = Math.max(4, pos.x - 120) + 'px';
                        overlay.style.top = Math.max(4, pos.y - 22) + 'px';
                        inp.focus(); inp.select();
                    });

                    function hideEdit() {
                        document.getElementById('edit-overlay').style.display = 'none';
                        editNodeId = -1;
                    }
                    function commitEdit() {
                        if (editNodeId < 0) return;
                        var inp = document.getElementById('edit-input');
                        var val = inp.value.trim();
                        if (!val) { hideEdit(); return; }
                        if (editNodeId === 0) { question = val; } else { options[editNodeId - 1] = val; }
                        nodes.update({ id: editNodeId,
                            label: wrapLabel(val, editNodeId === 0 ? 34 : 30),
                            color: editNodeId === 0
                                ? { background: '#0d2137', border: '#58a6ff',
                                    highlight: { background: '#1a3a5e', border: '#79c0ff' } }
                                : { background: '#0d1f17', border: '#3fb950',
                                    highlight: { background: '#1a3a28', border: '#56d364' } }
                        });
                        hideEdit(); network.redraw();
                    }

                    var inp = document.getElementById('edit-input');
                    inp.addEventListener('keydown', function(e) {
                        if (e.key === 'Enter') { e.preventDefault(); commitEdit(); }
                        if (e.key === 'Escape') { hideEdit(); }
                    });
                    inp.addEventListener('blur', function() { setTimeout(hideEdit, 150); });

                    network.fit({ animation: false });
                    setTimeout(function() {
                        try { window.webkit.messageHandlers.graphHeight.postMessage(h + 24); } catch(e) {}
                    }, 250);
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
