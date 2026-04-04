import Foundation
import GRDB
import Observation

/// Indexes ~/.cortana/brain/ content with local embeddings for semantic search.
/// Uses nomic-embed-text via Ollama API. Stores chunks + embeddings in brain-index.db.
/// File watcher auto-reindexes on changes.
@MainActor
@Observable
final class BrainIndexer {
    static let shared = BrainIndexer()

    private(set) var chunkCount: Int = 0
    private(set) var lastIndexDate: Date?
    private(set) var isIndexing: Bool = false

    private var dbPool: DatabasePool?
    private let fm = FileManager.default
    private let brainDir: URL
    private let dbPath: String
    private var fileWatcher = FileWatcher()
    private var checkpointTimer: DispatchSourceTimer?

    private let ollamaURL = "http://localhost:11434/api/embed"
    private let embeddingModel = "nomic-embed-text"
    private let chunkSize = 512
    private let chunkOverlap = 128
    private var embeddingCache: [(Int64, Data)] = []

    private init() {
        let home = fm.homeDirectoryForCurrentUser
        brainDir = home.appendingPathComponent(".cortana/brain")
        dbPath = home.appendingPathComponent(".cortana/brain-index.db").path
        openDatabase()
        startCheckpointTimer()
    }

    private func startCheckpointTimer() {
        guard dbPool != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            try? self?.dbPool?.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)")
            }
        }
        timer.resume()
        checkpointTimer = timer
    }

    // MARK: - Database

    private func openDatabase() {
        do {
            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA busy_timeout = 5000")
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            dbPool = try DatabasePool(path: dbPath, configuration: config)
            try createSchema()
            refreshCount()
            wtLog("[BrainIndexer] Connected to brain-index.db")
        } catch {
            wtLog("[BrainIndexer] Failed to open database: \(error)")
        }
    }

    private func createSchema() throws {
        guard let dbPool else { return }
        try dbPool.writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS brain_chunks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    file_path TEXT NOT NULL,
                    chunk_index INTEGER NOT NULL,
                    content TEXT NOT NULL,
                    embedding BLOB NOT NULL,
                    updated_at TEXT DEFAULT (datetime('now')),
                    UNIQUE(file_path, chunk_index)
                )
            """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS brain_fts USING fts5(
                    content, file_path, content='brain_chunks', content_rowid='id'
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS brain_index_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT
                )
            """)
        }
    }

    private func refreshCount() {
        guard let dbPool else { return }
        do {
            chunkCount = try dbPool.unsafeReentrantRead { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM brain_chunks")
            } ?? 0
        } catch {
            wtLog("[BrainIndexer] Failed to refresh chunk count: \(error)")
        }
    }

    // MARK: - Full Index

    func indexAll() async {
        guard !isIndexing else { return }

        // Check Ollama health before starting — skip if offline
        if !QualityRouter.shared.ollamaOnline {
            wtLog("[BrainIndexer] Skipping index — Ollama offline")
            return
        }

        isIndexing = true
        defer {
            isIndexing = false
            refreshCount()
            lastIndexDate = Date()
        }

        let files = collectMarkdownFiles()
        wtLog("[BrainIndexer] Indexing \(files.count) brain files...")

        for file in files {
            await indexFile(file)
        }

        do {
            try await dbPool?.write { db in
                try db.execute(sql: "INSERT INTO brain_fts(brain_fts) VALUES('rebuild')")
            }
        } catch {
            wtLog("[BrainIndexer] FTS rebuild failed: \(error)")
        }

        // Refresh embedding cache for fast semantic search
        if let dbPool {
            do {
                embeddingCache = try await dbPool.read { db in
                    try Row.fetchAll(db, sql: "SELECT id, embedding FROM brain_chunks").map { row in
                        (row["id"] as Int64, row["embedding"] as Data)
                    }
                }
            } catch {
                wtLog("[BrainIndexer] Failed to refresh embedding cache: \(error)")
            }
        }

        wtLog("[BrainIndexer] Index complete — \(chunkCount) chunks")
    }

    private func indexFile(_ url: URL) async {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let relativePath = url.path.replacingOccurrences(of: brainDir.path + "/", with: "")
        let chunks = chunkText(content)

        for (index, chunk) in chunks.enumerated() {
            guard let embedding = await embed(chunk) else { continue }

            do {
                try await dbPool?.write { db in
                    try db.execute(sql: "DELETE FROM brain_fts WHERE rowid IN (SELECT id FROM brain_chunks WHERE file_path = ? AND chunk_index = ?)",
                                   arguments: [relativePath, index])
                    try db.execute(sql: "DELETE FROM brain_chunks WHERE file_path = ? AND chunk_index = ?",
                                   arguments: [relativePath, index])
                    try db.execute(sql: "INSERT INTO brain_chunks (file_path, chunk_index, content, embedding, updated_at) VALUES (?, ?, ?, ?, datetime('now'))",
                                   arguments: [relativePath, index, chunk, embedding])
                    let rowid = db.lastInsertedRowID
                    try db.execute(sql: "INSERT INTO brain_fts(rowid, content, file_path) VALUES (?, ?, ?)",
                                   arguments: [rowid, chunk, relativePath])
                }
            } catch {
                wtLog("[BrainIndexer] Failed to store chunk \(index) of \(relativePath): \(error)")
            }
        }

        do {
            try await dbPool?.write { db in
                try db.execute(sql: "DELETE FROM brain_fts WHERE rowid IN (SELECT id FROM brain_chunks WHERE file_path = ? AND chunk_index >= ?)",
                               arguments: [relativePath, chunks.count])
                try db.execute(sql: "DELETE FROM brain_chunks WHERE file_path = ? AND chunk_index >= ?",
                               arguments: [relativePath, chunks.count])
            }
        } catch {
            wtLog("[BrainIndexer] Failed to clean stale chunks for \(relativePath): \(error)")
        }
    }

    // MARK: - Search

    struct SearchResult {
        let filePath: String
        let content: String
        let score: Float
        let matchType: String
    }

    func search(query: String, limit: Int = 10) async -> [SearchResult] {
        guard let dbPool else { return [] }

        let queryEmbedding = await embed(query)

        // FTS5 keyword results
        let ftsResults: [(Int64, String, String, Double)]
        do {
            ftsResults = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT bc.id, bc.file_path, bc.content, bm25(brain_fts) AS rank
                    FROM brain_fts
                    JOIN brain_chunks bc ON bc.id = brain_fts.rowid
                    WHERE brain_fts MATCH ?
                    ORDER BY rank LIMIT ?
                """, arguments: [query, limit * 2]).map { row in
                    let id: Int64 = row["id"]
                    let path: String = row["file_path"]
                    let content: String = row["content"]
                    let rank: Double = row["rank"]
                    return (id, path, content, rank)
                }
            }
        } catch {
            wtLog("[BrainIndexer] FTS search failed: \(error)")
            ftsResults = []
        }

        // Semantic results — use in-memory cache instead of DB query
        var semanticScores: [Int64: Float] = [:]
        if let queryEmb = queryEmbedding {
            // Fall back to DB if cache is empty (first search before indexAll completes)
            let chunks: [(Int64, Data)]
            if !embeddingCache.isEmpty {
                chunks = embeddingCache
            } else {
                do {
                    chunks = try await dbPool.read { db in
                        try Row.fetchAll(db, sql: "SELECT id, embedding FROM brain_chunks").map { row in
                            let id: Int64 = row["id"]
                            let emb: Data = row["embedding"]
                            return (id, emb)
                        }
                    }
                } catch {
                    wtLog("[BrainIndexer] Semantic search failed: \(error)")
                    chunks = []
                }
            }
            for (id, embData) in chunks {
                let similarity = cosineSimilarity(queryEmb, embData)
                if similarity > 0.5 {
                    semanticScores[id] = similarity
                }
            }
        }

        // Combine
        var combined: [Int64: (String, String, Float, String)] = [:]

        for (id, path, content, rank) in ftsResults {
            let ftsScore = Float(max(0, 1.0 + rank))
            let semScore = semanticScores[id] ?? 0
            if semScore > 0 {
                combined[id] = (path, content, 0.4 * ftsScore + 0.6 * semScore, "hybrid")
            } else {
                combined[id] = (path, content, ftsScore, "keyword")
            }
        }

        // Add semantic-only results
        if queryEmbedding != nil {
            do {
                let allInfo = try await dbPool.read { db in
                    try Row.fetchAll(db, sql: "SELECT id, file_path, content FROM brain_chunks").map { row in
                        let id: Int64 = row["id"]
                        let path: String = row["file_path"]
                        let content: String = row["content"]
                        return (id, path, content)
                    }
                }
                for (id, path, content) in allInfo {
                    if combined[id] == nil, let score = semanticScores[id], score > 0.6 {
                        combined[id] = (path, content, score, "semantic")
                    }
                }
            } catch {
                wtLog("[BrainIndexer] Semantic-only lookup failed: \(error)")
            }
        }

        return combined.values
            .sorted { $0.2 > $1.2 }
            .prefix(limit)
            .map { SearchResult(filePath: $0.0, content: $0.1, score: $0.2, matchType: $0.3) }
    }

    // MARK: - Embedding

    private func embed(_ text: String) async -> Data? {
        guard let url = URL(string: ollamaURL) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let payload: [String: Any] = ["model": embeddingModel, "input": text]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let embeddings = json["embeddings"] as? [[Double]],
                  let first = embeddings.first else { return nil }

            var floats = first.map { Float($0) }
            return Data(bytes: &floats, count: floats.count * MemoryLayout<Float>.size)
        } catch {
            wtLog("[BrainIndexer] Embed failed: \(error)")
            return nil
        }
    }

    private func cosineSimilarity(_ a: Data, _ b: Data) -> Float {
        let count = a.count / MemoryLayout<Float>.size
        guard count > 0, a.count == b.count else { return 0 }

        return a.withUnsafeBytes { aPtr in
            b.withUnsafeBytes { bPtr in
                let aFloats = aPtr.bindMemory(to: Float.self)
                let bFloats = bPtr.bindMemory(to: Float.self)
                var dot: Float = 0, normA: Float = 0, normB: Float = 0
                for i in 0..<count {
                    dot += aFloats[i] * bFloats[i]
                    normA += aFloats[i] * aFloats[i]
                    normB += bFloats[i] * bFloats[i]
                }
                let denom = sqrt(normA) * sqrt(normB)
                return denom > 0 ? dot / denom : 0
            }
        }
    }

    // MARK: - Chunking

    private func chunkText(_ text: String) -> [String] {
        let charChunkSize = chunkSize * 4
        let charOverlap = chunkOverlap * 4
        guard text.count > charChunkSize else { return [text] }

        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let endOffset = text.index(start, offsetBy: charChunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<endOffset]))
            if endOffset == text.endIndex { break }
            start = text.index(endOffset, offsetBy: -charOverlap, limitedBy: text.startIndex) ?? text.startIndex
        }
        return chunks
    }

    // MARK: - File Collection

    private func collectMarkdownFiles() -> [URL] {
        guard let enumerator = fm.enumerator(
            at: brainDir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "md" {
            files.append(url)
        }
        return files
    }

    // MARK: - Watch

    func startWatching() {
        fileWatcher.stopAll()
        let dirs = [brainDir,
                    brainDir.appendingPathComponent("CIC"),
                    brainDir.appendingPathComponent("Galactica"),
                    brainDir.appendingPathComponent("Pegasus"),
                    brainDir.appendingPathComponent("Knowledge"),
                    brainDir.appendingPathComponent("projects")]
        var count = 0
        for dir in dirs {
            guard fm.fileExists(atPath: dir.path) else { continue }
            fileWatcher.watch(dir.path, events: [.write, .rename]) { [weak self] in
                Task { @MainActor in await self?.indexAll() }
            }
            count += 1
        }
        wtLog("[BrainIndexer] Watching \(count) brain directories")
    }

    func stopWatching() {
        fileWatcher.stopAll()
    }
}
