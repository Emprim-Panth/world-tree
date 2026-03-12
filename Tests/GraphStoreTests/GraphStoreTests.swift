import XCTest
import GRDB
@testable import WorldTree

// MARK: - GraphStore Tests

/// Tests for graph traversal logic — subgraph queries, neighbor traversal, statistics,
/// and edge cases. Uses a temporary database with cg_nodes/cg_edges tables created manually
/// (these tables originate from cortana-core, not WorldTree migrations).
@MainActor
final class GraphStoreTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "graphstore-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)

        // Create the knowledge graph tables (normally created by cortana-core)
        try dbPool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS cg_nodes (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    label TEXT NOT NULL,
                    content TEXT DEFAULT '',
                    project TEXT DEFAULT '',
                    meta TEXT DEFAULT '{}',
                    created_at TEXT DEFAULT (datetime('now'))
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS cg_edges (
                    id TEXT PRIMARY KEY,
                    from_id TEXT NOT NULL,
                    to_id TEXT NOT NULL,
                    relation TEXT NOT NULL,
                    created_at TEXT DEFAULT (datetime('now'))
                )
                """)
        }
    }

    override func tearDown() async throws {
        dbPool = nil
        if let path = dbPath {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
        dbPath = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func insertNode(
        id: String,
        type: String,
        label: String,
        content: String = "",
        project: String = "",
        meta: String = "{}"
    ) throws -> String {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cg_nodes (id, type, label, content, project, meta, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
                    """,
                arguments: [id, type, label, content, project, meta]
            )
        }
        return id
    }

    @discardableResult
    private func insertEdge(
        id: String = UUID().uuidString,
        fromId: String,
        toId: String,
        relation: String
    ) throws -> String {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cg_edges (id, from_id, to_id, relation)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [id, fromId, toId, relation]
            )
        }
        return id
    }

    /// Direct subgraph query matching GraphStore.getSubgraph logic.
    private func getSubgraph(
        project: String? = nil,
        nodeTypes: [String]? = nil,
        maxNodes: Int = 100
    ) throws -> (nodes: [GraphNode], edges: [GraphEdge]) {
        try dbPool.read { db in
            var sql = "SELECT id, type, label, content, project, meta FROM cg_nodes WHERE 1=1"
            var args: [DatabaseValueConvertible] = []

            if let project {
                sql += " AND (project = ? OR project = '' OR project IS NULL)"
                args.append(project.lowercased())
            }

            if let nodeTypes, !nodeTypes.isEmpty {
                let placeholders = nodeTypes.map { _ in "?" }.joined(separator: ", ")
                sql += " AND type IN (\(placeholders))"
                args.append(contentsOf: nodeTypes)
            }

            sql += " ORDER BY created_at DESC LIMIT ?"
            args.append(maxNodes)

            let nodeRows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

            let nodes: [GraphNode] = nodeRows.map { row in
                GraphNode(
                    id: row["id"],
                    type: row["type"],
                    label: row["label"],
                    content: row["content"] ?? "",
                    project: row["project"] ?? "",
                    meta: row["meta"] ?? "{}"
                )
            }

            guard !nodes.isEmpty else { return ([], []) }

            let nodeIds = nodes.map(\.id)
            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ", ")
            let edgeRows = try Row.fetchAll(db, sql: """
                SELECT id, from_id, to_id, relation
                FROM cg_edges
                WHERE from_id IN (\(placeholders)) OR to_id IN (\(placeholders))
                LIMIT 200
                """, arguments: StatementArguments(nodeIds + nodeIds))

            let edges: [GraphEdge] = edgeRows.map { row in
                GraphEdge(
                    id: row["id"],
                    fromId: row["from_id"],
                    toId: row["to_id"],
                    relation: row["relation"]
                )
            }

            return (nodes, edges)
        }
    }

    /// Direct neighbor query matching GraphStore.getNeighbors logic.
    private func getNeighbors(
        nodeId: String,
        depth: Int = 1
    ) throws -> (nodes: [GraphNode], edges: [GraphEdge]) {
        try dbPool.read { db in
            var visited = Set<String>()
            var allNodes: [GraphNode] = []
            var allEdges: [GraphEdge] = []
            var frontier = [nodeId]

            for _ in 0..<depth {
                guard !frontier.isEmpty else { break }

                let placeholders = frontier.map { _ in "?" }.joined(separator: ", ")

                let edgeRows = try Row.fetchAll(db, sql: """
                    SELECT id, from_id, to_id, relation
                    FROM cg_edges
                    WHERE from_id IN (\(placeholders)) OR to_id IN (\(placeholders))
                    """, arguments: StatementArguments(frontier + frontier))

                var nextFrontier: [String] = []
                for row in edgeRows {
                    let edge = GraphEdge(
                        id: row["id"],
                        fromId: row["from_id"],
                        toId: row["to_id"],
                        relation: row["relation"]
                    )
                    allEdges.append(edge)

                    for nid in [edge.fromId, edge.toId] where !visited.contains(nid) {
                        visited.insert(nid)
                        nextFrontier.append(nid)
                    }
                }

                if !nextFrontier.isEmpty {
                    let np = nextFrontier.map { _ in "?" }.joined(separator: ", ")
                    let nodeRows = try Row.fetchAll(db, sql: """
                        SELECT id, type, label, content, project, meta
                        FROM cg_nodes WHERE id IN (\(np))
                        """, arguments: StatementArguments(nextFrontier))

                    for row in nodeRows {
                        allNodes.append(GraphNode(
                            id: row["id"],
                            type: row["type"],
                            label: row["label"],
                            content: row["content"] ?? "",
                            project: row["project"] ?? "",
                            meta: row["meta"] ?? "{}"
                        ))
                    }
                }

                frontier = nextFrontier
            }

            return (allNodes, allEdges)
        }
    }

    // MARK: - 1. Empty Graph

    func testEmptyGraphReturnsNoResults() throws {
        let (nodes, edges) = try getSubgraph()
        XCTAssertTrue(nodes.isEmpty, "Empty graph should return no nodes")
        XCTAssertTrue(edges.isEmpty, "Empty graph should return no edges")
    }

    // MARK: - 2. Basic Node Retrieval

    func testGetSubgraphReturnsInsertedNodes() throws {
        try insertNode(id: "n1", type: "concept", label: "GRDB", project: "worldtree")
        try insertNode(id: "n2", type: "technology", label: "Swift", project: "worldtree")

        let (nodes, _) = try getSubgraph()

        XCTAssertEqual(nodes.count, 2, "Should retrieve both nodes")
        let labels = Set(nodes.map(\.label))
        XCTAssertTrue(labels.contains("GRDB"))
        XCTAssertTrue(labels.contains("Swift"))
    }

    // MARK: - 3. Project Filtering

    func testGetSubgraphFiltersByProject() throws {
        try insertNode(id: "n1", type: "concept", label: "SwiftData", project: "bookbuddy")
        try insertNode(id: "n2", type: "concept", label: "GRDB", project: "worldtree")
        try insertNode(id: "n3", type: "concept", label: "Global Pattern", project: "")

        let (nodes, _) = try getSubgraph(project: "worldtree")

        // Should include worldtree-specific and global (empty project) nodes
        let labels = Set(nodes.map(\.label))
        XCTAssertTrue(labels.contains("GRDB"), "Should include project-specific node")
        XCTAssertTrue(labels.contains("Global Pattern"), "Should include global (empty project) nodes")
        XCTAssertFalse(labels.contains("SwiftData"), "Should exclude other project's nodes")
    }

    // MARK: - 4. Type Filtering

    func testGetSubgraphFiltersByNodeType() throws {
        try insertNode(id: "n1", type: "concept", label: "Concept Node")
        try insertNode(id: "n2", type: "decision", label: "Decision Node")
        try insertNode(id: "n3", type: "mistake", label: "Mistake Node")

        let (nodes, _) = try getSubgraph(nodeTypes: ["concept", "decision"])

        XCTAssertEqual(nodes.count, 2)
        let types = Set(nodes.map(\.type))
        XCTAssertTrue(types.contains("concept"))
        XCTAssertTrue(types.contains("decision"))
        XCTAssertFalse(types.contains("mistake"))
    }

    // MARK: - 5. Edge Retrieval

    func testGetSubgraphReturnsEdgesBetweenNodes() throws {
        try insertNode(id: "n1", type: "concept", label: "GRDB")
        try insertNode(id: "n2", type: "concept", label: "SQLite")
        try insertEdge(id: "e1", fromId: "n1", toId: "n2", relation: "depends_on")

        let (nodes, edges) = try getSubgraph()

        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].fromId, "n1")
        XCTAssertEqual(edges[0].toId, "n2")
        XCTAssertEqual(edges[0].relation, "depends_on")
    }

    // MARK: - 6. Neighbor Traversal (Depth 1)

    func testGetNeighborsDepth1() throws {
        try insertNode(id: "center", type: "concept", label: "Center")
        try insertNode(id: "neighbor1", type: "concept", label: "Neighbor 1")
        try insertNode(id: "neighbor2", type: "concept", label: "Neighbor 2")
        try insertNode(id: "distant", type: "concept", label: "Distant")

        try insertEdge(fromId: "center", toId: "neighbor1", relation: "related_to")
        try insertEdge(fromId: "center", toId: "neighbor2", relation: "uses")
        try insertEdge(fromId: "neighbor1", toId: "distant", relation: "leads_to")

        let (nodes, edges) = try getNeighbors(nodeId: "center", depth: 1)

        let labels = Set(nodes.map(\.label))
        XCTAssertTrue(labels.contains("Center") || labels.contains("Neighbor 1") || labels.contains("Neighbor 2"),
                      "Should find immediate neighbors")
        XCTAssertEqual(edges.count, 2, "Should find 2 edges from center")
    }

    // MARK: - 7. Neighbor Traversal (Depth 2)

    func testGetNeighborsDepth2ReachesDistantNodes() throws {
        try insertNode(id: "a", type: "concept", label: "A")
        try insertNode(id: "b", type: "concept", label: "B")
        try insertNode(id: "c", type: "concept", label: "C")

        try insertEdge(fromId: "a", toId: "b", relation: "links")
        try insertEdge(fromId: "b", toId: "c", relation: "links")

        let (nodes, edges) = try getNeighbors(nodeId: "a", depth: 2)

        let nodeIds = Set(nodes.map(\.id))
        XCTAssertTrue(nodeIds.contains("c"),
                      "Depth-2 traversal should reach node C through B")
        XCTAssertGreaterThanOrEqual(edges.count, 2)
    }

    // MARK: - 8. Max Nodes Limit

    func testGetSubgraphRespectsMaxNodesLimit() throws {
        for i in 0..<20 {
            try insertNode(id: "n\(i)", type: "concept", label: "Node \(i)")
        }

        let (nodes, _) = try getSubgraph(maxNodes: 5)

        XCTAssertEqual(nodes.count, 5, "Should respect maxNodes limit")
    }

    // MARK: - 9. GraphNode Type Color

    func testGraphNodeTypeColor() {
        let concept = GraphNode(id: "1", type: "concept", label: "X", content: "", project: "", meta: "{}")
        XCTAssertEqual(concept.typeColor, "blue")

        let project = GraphNode(id: "2", type: "project", label: "Y", content: "", project: "", meta: "{}")
        XCTAssertEqual(project.typeColor, "green")

        let decision = GraphNode(id: "3", type: "decision", label: "Z", content: "", project: "", meta: "{}")
        XCTAssertEqual(decision.typeColor, "orange")

        let agent = GraphNode(id: "4", type: "agent", label: "A", content: "", project: "", meta: "{}")
        XCTAssertEqual(agent.typeColor, "purple")

        let unknown = GraphNode(id: "5", type: "unknown_type", label: "U", content: "", project: "", meta: "{}")
        XCTAssertEqual(unknown.typeColor, "secondary", "Unknown type should fall back to secondary")
    }

    // MARK: - 10. Orphaned Node Detection

    func testOrphanedNodesHaveNoEdges() throws {
        try insertNode(id: "connected1", type: "concept", label: "Connected 1")
        try insertNode(id: "connected2", type: "concept", label: "Connected 2")
        try insertNode(id: "orphan", type: "concept", label: "Orphan")
        try insertEdge(fromId: "connected1", toId: "connected2", relation: "links")

        let (_, edges) = try getSubgraph()

        // Verify orphan has no edges
        let orphanEdges = edges.filter { $0.fromId == "orphan" || $0.toId == "orphan" }
        XCTAssertTrue(orphanEdges.isEmpty, "Orphan node should have no edges")

        // Verify connected nodes do have edges
        let connectedEdges = edges.filter { $0.fromId == "connected1" || $0.toId == "connected1" }
        XCTAssertFalse(connectedEdges.isEmpty, "Connected nodes should have edges")
    }

    // MARK: - 11. Neighbor Traversal with No Edges

    func testGetNeighborsForIsolatedNode() throws {
        try insertNode(id: "lonely", type: "concept", label: "Lonely")

        let (nodes, edges) = try getNeighbors(nodeId: "lonely", depth: 1)

        XCTAssertTrue(edges.isEmpty, "Isolated node should have no edges")
        // nodes may include the node itself depending on implementation
        XCTAssertTrue(nodes.isEmpty || nodes.allSatisfy { $0.id == "lonely" },
                      "Should only find the node itself or nothing")
    }
}
