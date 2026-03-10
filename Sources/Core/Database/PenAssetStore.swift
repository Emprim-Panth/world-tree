import Foundation
import GRDB

// MARK: - PenAsset

struct PenAsset: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "pen_assets"

    let id: String          // Stable hash of file path
    let project: String
    var filePath: String
    var fileName: String
    var frameCount: Int
    var nodeCount: Int
    var rawJson: String?
    var lastParsed: String?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, project
        case filePath = "file_path"
        case fileName = "file_name"
        case frameCount = "frame_count"
        case nodeCount = "node_count"
        case rawJson = "raw_json"
        case lastParsed = "last_parsed"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - PenFrameLink

struct PenFrameLink: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "pen_frame_links"

    let id: String
    var assetId: String
    var frameId: String
    var frameName: String?
    var ticketId: String?
    var annotation: String?
    var width: Double?
    var height: Double?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case assetId = "asset_id"
        case frameId = "frame_id"
        case frameName = "frame_name"
        case ticketId = "ticket_id"
        case annotation
        case width, height
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - PenFrameLinkWithTicket

struct PenFrameLinkWithTicket {
    let link: PenFrameLink
    let ticket: Ticket?
}

// MARK: - PenAssetStore

@MainActor
final class PenAssetStore: ObservableObject {
    static let shared = PenAssetStore()

    @Published private(set) var assets: [PenAsset] = []
    @Published private(set) var frameLinks: [PenFrameLink] = []

    private var pool: DatabasePool? { DatabaseManager.shared.dbPool }

    // MARK: - Assets

    func loadAssets(project: String) async {
        guard let pool else { return }
        do {
            assets = try await pool.read { db in
                try PenAsset.fetchAll(db, sql: """
                    SELECT * FROM pen_assets WHERE project = ? ORDER BY file_name ASC
                    """, arguments: [project])
            }
        } catch { }
    }

    /// Import or re-import a .pen file. Parses the JSON, upserts the asset record,
    /// syncs frame links, and resolves annotation → ticket_id links.
    func importFile(at url: URL, project: String) async throws {
        guard let pool else { return }

        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(PencilDocument.self, from: data)
        let rawJson = String(data: data, encoding: .utf8)
        let now = ISO8601DateFormatter().string(from: Date())
        let allFrames = document.allFrames
        let assetId = assetID(for: url)
        let filePath = url.path
        let fileName = url.lastPathComponent
        let frameCount = allFrames.count
        let nodeCount = document.totalNodeCount

        try await pool.write { db in
            // Preserve original createdAt on upsert
            let existingCreatedAt = (try? PenAsset
                .fetchOne(db, sql: "SELECT * FROM pen_assets WHERE id = ?", arguments: [assetId]))?
                .createdAt

            let asset = PenAsset(
                id: assetId,
                project: project,
                filePath: filePath,
                fileName: fileName,
                frameCount: frameCount,
                nodeCount: nodeCount,
                rawJson: rawJson,
                lastParsed: now,
                createdAt: existingCreatedAt ?? now,
                updatedAt: now
            )
            try asset.upsert(db)

            // Sync frame links — delete stale, upsert current
            try db.execute(sql: "DELETE FROM pen_frame_links WHERE asset_id = ?", arguments: [assetId])

            for frame in allFrames {
                let resolvedTicketId: String? = frame.annotation.flatMap { annotation in
                    try? String.fetchOne(db,
                        sql: "SELECT id FROM canvas_tickets WHERE id = ? AND project = ?",
                        arguments: [annotation, project])
                }
                let link = PenFrameLink(
                    id: "\(assetId)-\(frame.id)",
                    assetId: assetId,
                    frameId: frame.id,
                    frameName: frame.name,
                    ticketId: resolvedTicketId,
                    annotation: frame.annotation,
                    width: frame.width,
                    height: frame.height,
                    createdAt: now,
                    updatedAt: now
                )
                try link.upsert(db)
            }
        }

        await loadAssets(project: project)
        await loadFrameLinks(assetId: assetId)
    }

    func deleteAsset(id: String, project: String) async throws {
        guard let pool else { return }
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM pen_assets WHERE id = ?", arguments: [id])
        }
        await loadAssets(project: project)
    }

    // MARK: - Frame Links

    func loadFrameLinks(assetId: String) async {
        guard let pool else { return }
        do {
            frameLinks = try await pool.read { db in
                try PenFrameLink.fetchAll(db, sql: """
                    SELECT * FROM pen_frame_links WHERE asset_id = ? ORDER BY frame_name ASC
                    """, arguments: [assetId])
            }
        } catch { }
    }

    func frameLinksWithTickets(assetId: String) async -> [PenFrameLinkWithTicket] {
        guard let pool else { return [] }
        do {
            return try await pool.read { db in
                let links = try PenFrameLink.fetchAll(db, sql: """
                    SELECT * FROM pen_frame_links WHERE asset_id = ? ORDER BY frame_name ASC
                    """, arguments: [assetId])
                return links.map { link in
                    let ticket: Ticket? = link.ticketId.flatMap { tid in
                        try? Ticket.fetchOne(db, sql: "SELECT * FROM canvas_tickets WHERE id = ?", arguments: [tid])
                    }
                    return PenFrameLinkWithTicket(link: link, ticket: ticket)
                }
            }
        } catch {
            return []
        }
    }

    /// Re-resolve all annotation → ticket_id links for a given project.
    func resolveLinks(project: String) async throws {
        guard let pool else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        try await pool.write { db in
            let links = try PenFrameLink.fetchAll(db, sql: """
                SELECT fl.* FROM pen_frame_links fl
                JOIN pen_assets a ON a.id = fl.asset_id
                WHERE a.project = ? AND fl.annotation IS NOT NULL
                """, arguments: [project])

            for link in links {
                guard let annotation = link.annotation else { continue }
                var updated = link
                updated.ticketId = try? String.fetchOne(db,
                    sql: "SELECT id FROM canvas_tickets WHERE id = ? AND project = ?",
                    arguments: [annotation, project])
                updated.updatedAt = now
                try updated.upsert(db)
            }
        }
    }

    // MARK: - Helpers

    /// Stable ID for a file — FNV-1a hash of the canonical path
    private func assetID(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        var hash: UInt64 = 14695981039346656037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%016llx", hash)
    }
}
