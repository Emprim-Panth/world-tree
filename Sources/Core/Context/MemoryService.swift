import Foundation
import GRDB

/// Thread-safe box for passing a String result between queues.
/// @unchecked Sendable because access is synchronized via DispatchSemaphore
/// (write happens-before signal, read happens-after wait).
private final class RecallResultBox: @unchecked Sendable {
    var value: String = ""
}

/// Cross-session memory recall — searches conversation archive, knowledge base,
/// and recent session summaries to build contextual memory blocks injected into
/// every message send. This gives Claude awareness of past conversations.
///
/// Token-budget aware (~2000 tokens / ~8000 chars max). Degrades gracefully
/// if tables are missing or queries fail.
///
/// The heavy DB/FTS work runs on a background queue with a 200ms timeout so
/// slow queries never block the UI thread. On timeout, recall returns an empty
/// string and the message sends without cross-session memory.
@MainActor
final class MemoryService {
    static let shared = MemoryService()

    private var db: DatabaseManager { .shared }

    /// Maximum characters for the entire memory block (~2000 tokens)
    private let maxMemoryChars = 8000

    /// Maximum characters per individual snippet
    private let maxSnippetChars = 400

    /// How long to wait for DB recall before giving up (milliseconds)
    private nonisolated static let recallTimeoutMs: Int = 200

    /// Background queue for DB recall work — serial to avoid contention
    private nonisolated static let recallQueue = DispatchQueue(label: "com.worldtree.memoryservice.recall", qos: .userInitiated)

    /// Cache for tableExists checks — once a table exists, it won't disappear mid-session.
    /// Protected by cacheLock since it's accessed from the background recall queue.
    /// Marked nonisolated(unsafe) so the nonisolated static methods can access them —
    /// thread safety is guaranteed by cacheLock.
    nonisolated(unsafe) private static var tableExistsCache: [String: Bool] = [:]
    private nonisolated static let cacheLock = NSLock()

    /// FTS stop words — static to avoid re-allocating 100+ strings per call.
    /// Nonisolated since it's immutable and accessed from the background recall queue.
    private nonisolated static let stopWords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been",
        "being", "have", "has", "had", "do", "does", "did", "will",
        "would", "could", "should", "may", "might", "can", "shall",
        "to", "of", "in", "for", "on", "with", "at", "by", "from",
        "as", "into", "through", "during", "before", "after", "above",
        "below", "between", "out", "off", "about", "up", "down",
        "and", "but", "or", "nor", "not", "so", "yet", "both",
        "either", "neither", "each", "every", "all", "any", "few",
        "more", "most", "other", "some", "such", "no", "only", "own",
        "same", "than", "too", "very", "just", "because", "if",
        "when", "where", "how", "what", "which", "who", "whom",
        "this", "that", "these", "those", "i", "me", "my", "we",
        "you", "your", "he", "she", "it", "they", "them", "its",
        "his", "her", "our", "their", "let", "lets", "please",
        "want", "need", "like", "look", "make", "get", "go",
    ]

    private init() {}

    // MARK: - Primary API

    /// Build a memory block combining recent activity + relevant past conversations.
    ///
    /// Dispatches the DB work to a background queue and waits up to 200ms.
    /// If the query takes longer, returns empty string so the message send is
    /// never blocked by slow memory recall.
    ///
    /// - Parameters:
    ///   - message: The user's current message (used for FTS query terms)
    ///   - project: Current project name (for priority filtering)
    ///   - sessionId: Current session ID (excluded from results)
    /// - Returns: Formatted `<memory>` block, or empty string if nothing found or timed out
    func recallForMessage(
        _ message: String,
        project: String?,
        sessionId: String
    ) -> String {
        guard let dbPool = db.dbPool else { return "" }

        let maxChars = maxMemoryChars
        let maxSnippet = maxSnippetChars
        let timeoutMs = Self.recallTimeoutMs

        // Thread-safe box for passing the result back from the background queue.
        // Sendable because the lock guarantees exclusive access.
        let box = RecallResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        Self.recallQueue.async {
            let startTime = CFAbsoluteTimeGetCurrent()

            let output = Self.performRecall(
                dbPool: dbPool,
                message: message,
                project: project,
                sessionId: sessionId,
                maxMemoryChars: maxChars,
                maxSnippetChars: maxSnippet
            )

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

            if !output.isEmpty {
                wtLog("[MemoryService] recall: \(output.count) chars in \(Int(elapsed))ms")
            }

            box.value = output
            semaphore.signal()
        }

        let timeout = DispatchTime.now() + .milliseconds(timeoutMs)
        if semaphore.wait(timeout: timeout) == .timedOut {
            wtLog("[MemoryService] recall timed out after \(timeoutMs)ms, sending without cross-session memory")
            return ""
        }

        return box.value
    }

    // MARK: - Background Recall (nonisolated)

    /// Performs the actual DB recall work. Runs on the background recall queue.
    /// All parameters are passed by value — no actor-isolated state accessed.
    private nonisolated static func performRecall(
        dbPool: DatabasePool,
        message: String,
        project: String?,
        sessionId: String,
        maxMemoryChars: Int,
        maxSnippetChars: Int
    ) -> String {
        var sections: [String] = []
        var charBudget = maxMemoryChars

        // 1. Recent activity summary (always included — cheap, high value)
        let activity = recentActivitySummary(
            dbPool: dbPool,
            project: project,
            excludeSession: sessionId,
            charBudget: charBudget / 2,
            maxSnippetChars: maxSnippetChars
        )
        if !activity.isEmpty {
            sections.append("## Recent Activity\n\(activity)")
            charBudget -= activity.count + 20
        }

        // 2. FTS-matched past conversations (query-dependent)
        if charBudget > 500 && !message.isEmpty {
            let relevant = searchRelevantContext(
                dbPool: dbPool,
                query: message,
                project: project,
                excludeSession: sessionId,
                charBudget: charBudget,
                maxSnippetChars: maxSnippetChars
            )
            if !relevant.isEmpty {
                sections.append("## Relevant Past Conversations\n\(relevant)")
            }
        }

        guard !sections.isEmpty else { return "" }
        return "<memory>\n\(sections.joined(separator: "\n\n"))\n</memory>"
    }

    // MARK: - Recent Activity Summary

    /// Last N sessions' summaries from conversation_archive.
    /// Project-prioritized: current project's sessions come first.
    private nonisolated static func recentActivitySummary(
        dbPool: DatabasePool,
        project: String?,
        excludeSession: String,
        charBudget: Int,
        maxSnippetChars: Int
    ) -> String {
        do {
            return try dbPool.read { db -> String in
                // Check table exists
                guard try tableExists(db, name: "conversation_archive") else { return "" }

                var results: [String] = []
                var remaining = charBudget

                let sql: String
                let args: StatementArguments

                if let project {
                    sql = """
                        SELECT project, compressed_summary, key_decisions,
                               message_count, archived_at
                        FROM conversation_archive
                        WHERE session_id != ?
                        ORDER BY
                            CASE WHEN project = ? THEN 0 ELSE 1 END,
                            archived_at DESC
                        LIMIT 8
                        """
                    args = [excludeSession, project]
                } else {
                    sql = """
                        SELECT project, compressed_summary, key_decisions,
                               message_count, archived_at
                        FROM conversation_archive
                        WHERE session_id != ?
                        ORDER BY archived_at DESC
                        LIMIT 5
                        """
                    args = [excludeSession]
                }

                let rows = try Row.fetchAll(db, sql: sql, arguments: args)

                for row in rows {
                    guard remaining > 100 else { break }

                    let proj: String = row["project"] ?? "unknown"
                    let summary: String = row["compressed_summary"] ?? ""
                    let decisions: String? = row["key_decisions"]
                    let msgCount: Int = row["message_count"] ?? 0
                    let archivedAt: String = row["archived_at"] ?? ""

                    let datePart = String(archivedAt.prefix(10))

                    var entry = "- [\(proj)] \(datePart) (\(msgCount) msgs): "
                    let content = (decisions?.isEmpty == false) ? decisions! : summary
                    let truncated = String(content.prefix(min(maxSnippetChars, max(0, remaining - entry.count))))
                    entry += truncated

                    results.append(entry)
                    remaining -= entry.count + 1
                }

                return results.joined(separator: "\n")
            }
        } catch {
            wtLog("[MemoryService] recentActivitySummary failed: \(error)")
            return ""
        }
    }

    // MARK: - Relevant Context Search (FTS5)

    /// Search conversation_archive_fts and knowledge_fts for content matching the query.
    private nonisolated static func searchRelevantContext(
        dbPool: DatabasePool,
        query: String,
        project: String?,
        excludeSession: String,
        charBudget: Int,
        maxSnippetChars: Int
    ) -> String {
        let ftsQuery = buildFTSQuery(from: query)
        guard !ftsQuery.isEmpty else { return "" }

        do {
            return try dbPool.read { db -> String in
                var results: [String] = []
                var remaining = charBudget
                let halfBudget = charBudget / 2

                // Source 1: conversation_archive_fts — past session summaries
                let archiveHits = searchArchiveFTS(
                    db: db, query: ftsQuery,
                    excludeSession: excludeSession,
                    limit: 5
                )
                for hit in archiveHits {
                    guard remaining > 100 else { break }
                    let datePart = String(hit.date.prefix(10))
                    var entry = "- [\(hit.project)] \(datePart): "
                    let content = String(hit.summary.prefix(min(maxSnippetChars, max(0, remaining - entry.count))))
                    entry += content
                    results.append(entry)
                    remaining -= entry.count + 1
                    if remaining < halfBudget { break }
                }

                // Source 2: knowledge_fts — corrections, decisions, patterns
                let knowledgeHits = searchKnowledgeFTS(
                    db: db, query: ftsQuery,
                    limit: 3
                )
                for hit in knowledgeHits {
                    guard remaining > 100 else { break }
                    var entry = "- [\(hit.type)] \(hit.title): "
                    let content = String(hit.content.prefix(min(maxSnippetChars, max(0, remaining - entry.count))))
                    entry += content
                    results.append(entry)
                    remaining -= entry.count + 1
                }

                return results.joined(separator: "\n")
            }
        } catch {
            wtLog("[MemoryService] searchRelevantContext failed: \(error)")
            return ""
        }
    }

    // MARK: - FTS Search Helpers

    private struct ArchiveHit {
        let project: String
        let summary: String
        let date: String
    }

    private struct KnowledgeHit {
        let type: String
        let title: String
        let content: String
    }

    private nonisolated static func searchArchiveFTS(
        db: Database,
        query: String,
        excludeSession: String,
        limit: Int
    ) -> [ArchiveHit] {
        guard (try? tableExists(db, name: "conversation_archive_fts")) == true else { return [] }

        do {
            let rows = try Row.fetchAll(db, sql: """
                SELECT ca.project, ca.compressed_summary, ca.archived_at
                FROM conversation_archive ca
                JOIN conversation_archive_fts fts ON fts.rowid = ca.rowid
                WHERE conversation_archive_fts MATCH ?
                  AND ca.session_id != ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [query, excludeSession, limit])

            return rows.map { row in
                ArchiveHit(
                    project: (row["project"] as String?) ?? "unknown",
                    summary: (row["compressed_summary"] as String?) ?? "",
                    date: (row["archived_at"] as String?) ?? ""
                )
            }
        } catch {
            wtLog("[MemoryService] archive FTS query failed: \(error)")
            return []
        }
    }

    private nonisolated static func searchKnowledgeFTS(
        db: Database,
        query: String,
        limit: Int
    ) -> [KnowledgeHit] {
        guard (try? tableExists(db, name: "knowledge_fts")) == true else { return [] }

        // Check if knowledge table has is_active column (may not exist in all schemas)
        let hasIsActive = (try? db.columns(in: "knowledge").contains { $0.name == "is_active" }) ?? false

        do {
            let sql: String
            if hasIsActive {
                sql = """
                    SELECT k.type, k.title, k.content
                    FROM knowledge k
                    JOIN knowledge_fts ON knowledge_fts.rowid = k.rowid
                    WHERE knowledge_fts MATCH ?
                      AND k.is_active = 1
                    ORDER BY
                        CASE k.type
                            WHEN 'correction' THEN 0
                            WHEN 'decision' THEN 1
                            WHEN 'mistake' THEN 2
                            WHEN 'pattern' THEN 3
                            ELSE 4
                        END,
                        rank
                    LIMIT ?
                    """
            } else {
                sql = """
                    SELECT k.type, k.title, k.content
                    FROM knowledge k
                    JOIN knowledge_fts ON knowledge_fts.rowid = k.rowid
                    WHERE knowledge_fts MATCH ?
                    ORDER BY
                        CASE k.type
                            WHEN 'correction' THEN 0
                            WHEN 'decision' THEN 1
                            WHEN 'mistake' THEN 2
                            WHEN 'pattern' THEN 3
                            ELSE 4
                        END,
                        rank
                    LIMIT ?
                    """
            }

            let rows = try Row.fetchAll(db, sql: sql, arguments: [query, limit])

            return rows.map { row in
                KnowledgeHit(
                    type: (row["type"] as String?) ?? "knowledge",
                    title: (row["title"] as String?) ?? "",
                    content: (row["content"] as String?) ?? ""
                )
            }
        } catch {
            wtLog("[MemoryService] knowledge FTS query failed: \(error)")
            return []
        }
    }

    // MARK: - FTS Query Builder

    /// Build a safe FTS5 query from a natural language message.
    /// Extracts significant terms, removes FTS operators and stop words.
    /// Internal (not private) to allow unit testing from the test target.
    /// Instance convenience that delegates to the static implementation.
    func buildFTSQuery(from message: String) -> String {
        Self.buildFTSQuery(from: message)
    }

    /// Static implementation — callable from both the main actor and background queue.
    nonisolated static func buildFTSQuery(from message: String) -> String {
        // Strip FTS5 special characters
        let cleaned = message.lowercased()
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "*", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "^", with: " ")
            .replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
            .replacingOccurrences(of: "'", with: "")

        let words = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count >= 3 && !stopWords.contains($0) }

        var seen = Set<String>()
        let terms = words.filter { seen.insert($0).inserted }.prefix(8)
        guard !terms.isEmpty else { return "" }

        return terms.joined(separator: " OR ")
    }

    // MARK: - Utilities

    /// Thread-safe table existence check with caching.
    /// Uses NSLock since this is called from the background recall queue.
    private nonisolated static func tableExists(_ db: Database, name: String) throws -> Bool {
        cacheLock.lock()
        let cached = tableExistsCache[name]
        cacheLock.unlock()

        if let cached {
            return cached
        }

        let exists = try Bool.fetchOne(db, sql: """
            SELECT COUNT(*) > 0 FROM sqlite_master
            WHERE type = 'table' AND name = ?
            """, arguments: [name]) ?? false

        cacheLock.lock()
        tableExistsCache[name] = exists
        cacheLock.unlock()

        return exists
    }

    /// Reset the table-exists cache — used by tests to ensure fresh state between runs.
    static func resetTableExistsCache() {
        cacheLock.lock()
        tableExistsCache.removeAll()
        cacheLock.unlock()
    }
}
