import XCTest
import GRDB
@testable import WorldTree

// MARK: - BrainIndexer Unit Tests

/// Tests for BrainIndexer schema, chunking logic, cosine similarity, and FTS search.
/// Uses a temp database — does NOT require live Ollama.
@MainActor
final class BrainIndexerTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "brain-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)
        try createBrainSchema(dbPool)
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

    // MARK: - Schema

    func testSchemaCreationIsIdempotent() throws {
        // Call createSchema a second time — should not throw
        try createBrainSchema(dbPool)

        // Verify tables exist
        let tables = try dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        XCTAssertTrue(tables.contains("brain_chunks"), "brain_chunks table should exist")
        XCTAssertTrue(tables.contains("brain_index_meta"), "brain_index_meta table should exist")
    }

    func testSchemaHasExpectedColumns() throws {
        let columns = try dbPool.read { db in
            try db.columns(in: "brain_chunks").map(\.name)
        }
        XCTAssertTrue(columns.contains("id"))
        XCTAssertTrue(columns.contains("file_path"))
        XCTAssertTrue(columns.contains("chunk_index"))
        XCTAssertTrue(columns.contains("content"))
        XCTAssertTrue(columns.contains("embedding"))
        XCTAssertTrue(columns.contains("updated_at"))
    }

    // MARK: - Chunk Count After Seeding

    func testChunkCountAfterSeeding() throws {
        try seedChunks(count: 5)

        let count = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM brain_chunks")
        }
        XCTAssertEqual(count, 5, "Should have 5 chunks after seeding 5")
    }

    func testChunkCountEmptyDatabase() throws {
        let count = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM brain_chunks")
        }
        XCTAssertEqual(count, 0, "Empty database should have 0 chunks")
    }

    // MARK: - FTS Search via Raw SQL

    func testFTSKeywordMatchReturnsResults() throws {
        try seedChunksWithContent([
            ("knowledge/corrections.md", "Always verify database migrations before deploying"),
            ("knowledge/patterns.md", "Use GRDB ValueObservation for reactive queries"),
            ("identity/who-i-am.md", "Evan is a software developer building products"),
        ])

        let results = try dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT bc.file_path, bc.content
                FROM brain_fts
                JOIN brain_chunks bc ON bc.id = brain_fts.rowid
                WHERE brain_fts MATCH 'database'
                ORDER BY bm25(brain_fts)
            """)
        }

        XCTAssertGreaterThan(results.count, 0, "FTS should find 'database' in seeded content")
        let paths: [String] = results.map { $0["file_path"] }
        XCTAssertTrue(paths.contains("knowledge/corrections.md"))
    }

    func testFTSNoMatchReturnsEmpty() throws {
        try seedChunksWithContent([
            ("test.md", "Hello world this is a test document"),
        ])

        let results = try dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT bc.file_path
                FROM brain_fts
                JOIN brain_chunks bc ON bc.id = brain_fts.rowid
                WHERE brain_fts MATCH 'xylophone'
            """)
        }
        XCTAssertTrue(results.isEmpty, "No match should return empty results")
    }

    // MARK: - Chunking Logic

    /// Tests chunking behavior by replicating the algorithm from BrainIndexer.
    /// chunkText is private, so we test the same logic inline.
    func testShortTextProducesSingleChunk() {
        let text = "Short text that fits in one chunk."
        let chunks = chunkText(text, chunkSize: 512, chunkOverlap: 128)
        XCTAssertEqual(chunks.count, 1, "Short text should produce exactly 1 chunk")
        XCTAssertEqual(chunks.first, text)
    }

    func testLongTextProducesMultipleChunks() {
        // chunkSize=512 means charChunkSize=2048. Generate text longer than that.
        let text = String(repeating: "a", count: 5000)
        let chunks = chunkText(text, chunkSize: 512, chunkOverlap: 128)
        XCTAssertGreaterThan(chunks.count, 1, "Long text should produce multiple chunks")
    }

    func testChunkOverlapWorksCorrectly() {
        // 3000 chars with charChunkSize=2048 and charOverlap=512
        let text = String(repeating: "x", count: 3000)
        let chunks = chunkText(text, chunkSize: 512, chunkOverlap: 128)
        XCTAssertEqual(chunks.count, 2, "3000 chars with 2048 chunk size should produce 2 chunks")

        // Second chunk should start before the end of the first due to overlap
        let firstEnd = chunks[0].count
        let overlapChars = 128 * 4  // charOverlap
        // The second chunk starts at (firstEnd - overlapChars), so it overlaps
        XCTAssertGreaterThan(chunks[0].count + chunks[1].count, text.count,
                             "Total chunk content should exceed original due to overlap")
    }

    func testChunkTextEmptyString() {
        let chunks = chunkText("", chunkSize: 512, chunkOverlap: 128)
        XCTAssertEqual(chunks.count, 1, "Empty string should produce 1 chunk (passes guard)")
    }

    // MARK: - Cosine Similarity

    func testCosineSimilarityIdenticalVectors() {
        let vec = makeEmbeddingData([1.0, 2.0, 3.0])
        let similarity = cosineSimilarity(vec, vec)
        XCTAssertEqual(similarity, 1.0, accuracy: 0.0001, "Identical vectors should have similarity 1.0")
    }

    func testCosineSimilarityOrthogonalVectors() {
        let a = makeEmbeddingData([1.0, 0.0, 0.0])
        let b = makeEmbeddingData([0.0, 1.0, 0.0])
        let similarity = cosineSimilarity(a, b)
        XCTAssertEqual(similarity, 0.0, accuracy: 0.0001, "Orthogonal vectors should have similarity 0.0")
    }

    func testCosineSimilarityOppositeVectors() {
        let a = makeEmbeddingData([1.0, 2.0, 3.0])
        let b = makeEmbeddingData([-1.0, -2.0, -3.0])
        let similarity = cosineSimilarity(a, b)
        XCTAssertEqual(similarity, -1.0, accuracy: 0.0001, "Opposite vectors should have similarity -1.0")
    }

    func testCosineSimilarityEmptyData() {
        let a = Data()
        let b = Data()
        let similarity = cosineSimilarity(a, b)
        XCTAssertEqual(similarity, 0.0, "Empty data should return 0.0")
    }

    func testCosineSimilarityMismatchedSizes() {
        let a = makeEmbeddingData([1.0, 2.0])
        let b = makeEmbeddingData([1.0, 2.0, 3.0])
        let similarity = cosineSimilarity(a, b)
        XCTAssertEqual(similarity, 0.0, "Mismatched sizes should return 0.0")
    }

    // MARK: - Unique Constraint

    func testUniqueConstraintOnFilePathAndChunkIndex() throws {
        let embedding = makeEmbeddingData([0.1, 0.2, 0.3])

        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO brain_chunks (file_path, chunk_index, content, embedding)
                VALUES ('test.md', 0, 'first version', ?)
            """, arguments: [embedding])
        }

        // Insert with same file_path + chunk_index should conflict
        XCTAssertThrowsError(try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO brain_chunks (file_path, chunk_index, content, embedding)
                VALUES ('test.md', 0, 'second version', ?)
            """, arguments: [embedding])
        }, "Duplicate file_path + chunk_index should violate UNIQUE constraint")
    }

    // MARK: - Helpers

    private func createBrainSchema(_ dbPool: DatabasePool) throws {
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

    private func seedChunks(count: Int) throws {
        let embedding = makeEmbeddingData([0.1, 0.2, 0.3])
        try dbPool.write { db in
            for i in 0..<count {
                try db.execute(sql: """
                    INSERT INTO brain_chunks (file_path, chunk_index, content, embedding)
                    VALUES (?, ?, ?, ?)
                """, arguments: ["test.md", i, "Chunk \(i) content", embedding])
            }
        }
    }

    private func seedChunksWithContent(_ items: [(String, String)]) throws {
        let embedding = makeEmbeddingData([0.1, 0.2, 0.3])
        try dbPool.write { db in
            for (index, item) in items.enumerated() {
                try db.execute(sql: """
                    INSERT INTO brain_chunks (file_path, chunk_index, content, embedding)
                    VALUES (?, ?, ?, ?)
                """, arguments: [item.0, index, item.1, embedding])
                let rowid = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO brain_fts(rowid, content, file_path) VALUES (?, ?, ?)
                """, arguments: [rowid, item.1, item.0])
            }
        }
    }

    /// Replicates BrainIndexer.chunkText (private method) for testing.
    private func chunkText(_ text: String, chunkSize: Int, chunkOverlap: Int) -> [String] {
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

    /// Replicates BrainIndexer.cosineSimilarity (private method) for testing.
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

    private func makeEmbeddingData(_ values: [Float]) -> Data {
        var floats = values
        return Data(bytes: &floats, count: floats.count * MemoryLayout<Float>.size)
    }
}
