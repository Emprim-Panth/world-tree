import SwiftUI

/// Force-directed knowledge graph visualization.
struct GraphView: View {
    @State private var nodes: [GraphNode] = []
    @State private var edges: [GraphEdge] = []
    @State private var positions: [String: CGPoint] = [:]
    @State private var jitterCache: [String: CGFloat] = [:]
    @State private var lastLayoutSize: CGSize = .zero
    @State private var selectedNode: GraphNode?
    @State private var isLoading = false
    @State private var nodeCount = 0
    @State private var edgeCount = 0
    @State private var nodeTypes: [String: Int] = [:]
    @State private var filterType: String?

    var body: some View {
        HSplitView {
            // Graph canvas
            VStack(spacing: 0) {
                HStack {
                    Text("Knowledge Graph")
                        .font(.headline)

                    Spacer()

                    Text("\(nodeCount) nodes, \(edgeCount) edges")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Type filter
                    Menu {
                        Button("All Types") {
                            filterType = nil
                            Task { await loadGraph() }
                        }
                        Divider()
                        ForEach(Array(nodeTypes.keys.sorted()), id: \.self) { type in
                            Button("\(type) (\(nodeTypes[type] ?? 0))") {
                                filterType = type
                                Task { await loadGraph() }
                            }
                        }
                    } label: {
                        Label(filterType ?? "All", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.caption)
                    }
                    .accessibilityLabel("Filter node types")
                    .accessibilityValue(filterType ?? "All types")

                    Button {
                        Task { await loadGraph() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh graph")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                if isLoading {
                    ProgressView("Loading graph...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if nodes.isEmpty {
                    ContentUnavailableView(
                        "No Graph Data",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Run `python3 graph.py backfill` to populate the knowledge graph.")
                    )
                } else {
                    graphCanvas
                }
            }

            // Detail panel
            if let node = selectedNode {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(nodeColor(for: node.type))
                            .accessibilityLabel("Node type: \(node.type)")
                        Text(node.label)
                            .font(.headline)
                    }

                    Divider()

                    LabeledContent("Type", value: node.type)
                    if !node.project.isEmpty {
                        LabeledContent("Project", value: node.project)
                    }

                    if !node.content.isEmpty {
                        Text("Content")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(node.content.prefix(500)))
                            .font(.callout)
                            .padding(8)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    // Show connected edges
                    let connected = edges.filter { $0.fromId == node.id || $0.toId == node.id }
                    if !connected.isEmpty {
                        Text("Connections (\(connected.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(connected) { edge in
                            let other = edge.fromId == node.id ? edge.toId : edge.fromId
                            let otherLabel = nodes.first(where: { $0.id == other })?.label ?? other
                            let direction = edge.fromId == node.id ? "→" : "←"
                            Text("\(direction) \(edge.relation) — \(otherLabel)")
                                .font(.callout)
                        }
                    }

                    Spacer()
                }
                .padding()
                .frame(width: 280)
            }
        }
        .task { await loadGraph() }
    }

    private var graphCanvas: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in
                    // Draw edges
                    for edge in edges {
                        guard let from = positions[edge.fromId],
                              let to = positions[edge.toId] else { continue }
                        var path = Path()
                        path.move(to: from)
                        path.addLine(to: to)
                        context.stroke(path, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                    }

                    // Draw nodes
                    for node in nodes {
                        guard let pos = positions[node.id] else { continue }
                        let radius: CGFloat = node.id == selectedNode?.id ? 10 : 6
                        let rect = CGRect(x: pos.x - radius, y: pos.y - radius,
                                         width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(nodeColor(for: node.type)))

                        // Label
                        let text = Text(String(node.label.prefix(20)))
                            .font(.system(size: 9))
                            .foregroundStyle(.primary)
                        context.draw(text, at: CGPoint(x: pos.x, y: pos.y + radius + 8))
                    }
                }
                .onTapGesture { location in
                    // Find nearest node
                    let tapped = nodes.min { a, b in
                        let posA = positions[a.id] ?? .zero
                        let posB = positions[b.id] ?? .zero
                        let dA = hypot(posA.x - location.x, posA.y - location.y)
                        let dB = hypot(posB.x - location.x, posB.y - location.y)
                        return dA < dB
                    }
                    if let tapped, let pos = positions[tapped.id] {
                        let dist = hypot(pos.x - location.x, pos.y - location.y)
                        selectedNode = dist < 30 ? tapped : nil
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Knowledge graph visualization")
                .accessibilityValue("\(nodes.count) nodes, \(edges.count) edges" + (selectedNode.map { ". Selected: \($0.label)" } ?? ""))
                .accessibilityHint("Tap a node to view its details")

                // Hidden accessibility list of graph nodes for VoiceOver navigation
                ForEach(nodes) { node in
                    if let pos = positions[node.id] {
                        Color.clear
                            .frame(width: 24, height: 24)
                            .position(pos)
                            .accessibilityElement()
                            .accessibilityLabel("\(node.type): \(node.label)")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Select this node to view details")
                            .onTapGesture { selectedNode = node }
                    }
                }
            }
            .onChange(of: nodes) { _, newNodes in
                // Only relayout if node set actually changed (not just selection)
                if Set(newNodes.map(\.id)) != Set(positions.keys) {
                    layoutNodes(in: geometry.size)
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                guard newSize != lastLayoutSize else { return }
                layoutNodes(in: newSize)
            }
            .onAppear {
                layoutNodes(in: geometry.size)
            }
        }
    }

    private func loadGraph() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let stats = try await GraphStore.shared.getStats()
            nodeCount = stats.nodeCount
            edgeCount = stats.edgeCount
            nodeTypes = stats.nodeTypes

            let types = filterType.map { [$0] }
            let result = try await GraphStore.shared.getSubgraph(
                nodeTypes: types,
                maxNodes: 80
            )
            nodes = result.nodes
            edges = result.edges
        } catch {
            wtLog("[Graph] Failed to load: \(error)")
        }
    }

    /// Circular layout with type-based grouping and spiral expansion.
    /// Scales radius with node count to avoid overlap when count > 20.
    /// Uses concentric rings within each type group so nodes don't pile up.
    private func layoutNodes(in size: CGSize) {
        guard !nodes.isEmpty else { return }
        lastLayoutSize = size

        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        // Scale radius: base 35% of viewport, grows with sqrt(nodeCount) to spread nodes
        let baseRadius = min(size.width, size.height) * 0.35
        let scaleFactor = max(1.0, sqrt(CGFloat(nodes.count) / 20.0))
        let radius = baseRadius * scaleFactor

        // Minimum angular separation (in radians) to keep nodes from overlapping.
        // ~24px node diameter + label means we need about 30px between centers.
        let minSeparation: CGFloat = 30.0
        let minAngle = minSeparation / max(radius, 1.0)

        // Group nodes by type for visual clustering
        let grouped = Dictionary(grouping: nodes, by: \.type)
        var angle: CGFloat = 0
        let typeAngleStep = (2 * .pi) / CGFloat(max(grouped.count, 1))

        // How many nodes fit on one ring per type sector
        let maxPerRing = max(Int(typeAngleStep / minAngle), 1)
        let ringSpacing: CGFloat = 36.0 // pixels between concentric rings

        var newPositions: [String: CGPoint] = [:]

        for (_, typeNodes) in grouped {
            for (i, node) in typeNodes.enumerated() {
                let ring = i / maxPerRing
                let indexInRing = i % maxPerRing
                let nodesInThisRing = min(maxPerRing, typeNodes.count - ring * maxPerRing)
                let nodeAngleStep = typeAngleStep / CGFloat(max(nodesInThisRing, 1))
                let nodeAngle = angle + CGFloat(indexInRing) * nodeAngleStep

                // Stable per-node jitter — only generated once per node ID
                let jitter = jitterCache[node.id] ?? {
                    let j = CGFloat.random(in: -8...8)
                    jitterCache[node.id] = j
                    return j
                }()
                let ringOffset = CGFloat(ring) * ringSpacing
                let r = radius + ringOffset + jitter

                newPositions[node.id] = CGPoint(
                    x: center.x + r * cos(nodeAngle),
                    y: center.y + r * sin(nodeAngle)
                )
            }
            angle += typeAngleStep
        }

        positions = newPositions
    }

    private func nodeColor(for type: String) -> Color {
        switch type {
        case "concept": return .blue
        case "project": return .green
        case "decision": return .orange
        case "agent": return .purple
        case "technology": return .teal
        case "file": return .gray
        case "pattern": return .indigo
        case "mistake": return .red
        case "fix": return .mint
        case "anti_pattern": return .pink
        default: return .secondary
        }
    }
}
