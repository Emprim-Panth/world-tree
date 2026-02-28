import Foundation
import GRDB

/// Returns a comma-separated list of `?` placeholders for SQL IN clauses.
private func sqlPlaceholders(count: Int) -> String {
    repeatElement("?", count: count).joined(separator: ", ")
}

/// Graph node from the knowledge graph (cg_nodes table).
struct GraphNode: Identifiable, Hashable {
    let id: String
    let type: String
    let label: String
    let content: String
    let project: String
    let meta: String

    var typeColor: String {
        switch type {
        case "concept": return "blue"
        case "project": return "green"
        case "decision": return "orange"
        case "agent": return "purple"
        case "technology": return "teal"
        case "file": return "gray"
        case "pattern": return "indigo"
        case "mistake": return "red"
        default: return "secondary"
        }
    }
}

/// Graph edge from the knowledge graph (cg_edges table).
struct GraphEdge: Identifiable, Hashable {
    let id: String
    let fromId: String
    let toId: String
    let relation: String
}

/// Reads knowledge graph data from cg_nodes/cg_edges tables.
@MainActor
final class GraphStore {
    static let shared = GraphStore()

    private var db: DatabaseManager { .shared }

    private init() {}

    /// Get a subgraph filtered by project and/or node types.
    func getSubgraph(
        project: String? = nil,
        nodeTypes: [String]? = nil,
        maxNodes: Int = 100
    ) async throws -> (nodes: [GraphNode], edges: [GraphEdge]) {
        try await db.asyncRead { db in
            let hasCgNodes = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='cg_nodes'
                """) ?? false
            guard hasCgNodes else { return ([], []) }

            // Build node query
            var sql = "SELECT id, type, label, content, project, meta FROM cg_nodes WHERE 1=1"
            var args: [DatabaseValueConvertible] = []

            if let project {
                sql += " AND (project = ? OR project = '' OR project IS NULL)"
                args.append(project.lowercased())
            }

            if let nodeTypes, !nodeTypes.isEmpty {
                let placeholders = sqlPlaceholders(count: nodeTypes.count)
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

            // Get edges between these nodes
            let nodeIds = nodes.map(\.id)
            let placeholders = sqlPlaceholders(count: nodeIds.count)
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

    /// Get neighbors of a specific node up to a given depth.
    func getNeighbors(nodeId: String, depth: Int = 1) async throws -> (nodes: [GraphNode], edges: [GraphEdge]) {
        try await db.asyncRead { db in
            var visited = Set<String>()
            var allNodes: [GraphNode] = []
            var allEdges: [GraphEdge] = []
            var frontier = [nodeId]

            for _ in 0..<depth {
                guard !frontier.isEmpty else { break }

                let placeholders = sqlPlaceholders(count: frontier.count)

                // Get outgoing edges
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

                // Fetch node details for new discoveries
                if !nextFrontier.isEmpty {
                    let np = sqlPlaceholders(count: nextFrontier.count)
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

    /// Graph statistics.
    func getStats() async throws -> (nodeCount: Int, edgeCount: Int, nodeTypes: [String: Int]) {
        try await db.asyncRead { db in
            let hasCgNodes = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='cg_nodes'
                """) ?? false
            guard hasCgNodes else { return (0, 0, [:]) }

            let nodeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cg_nodes") ?? 0
            let edgeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cg_edges") ?? 0

            let typeRows = try Row.fetchAll(db, sql: """
                SELECT type, COUNT(*) as c FROM cg_nodes GROUP BY type ORDER BY c DESC
                """)
            var nodeTypes: [String: Int] = [:]
            for row in typeRows {
                let t: String = row["type"]
                let c: Int = row["c"]
                nodeTypes[t] = c
            }

            return (nodeCount, edgeCount, nodeTypes)
        }
    }
}
