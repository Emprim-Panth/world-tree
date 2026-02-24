import Foundation

/// Local SSD cache for World Tree. Two layers, zero Dropbox involvement.
///
/// **Stream files** — `.tmp` files written token-by-token during a live response.
/// Auto-deleted on successful completion. If the process dies mid-stream (SIGTERM etc),
/// the file survives and is recovered on next launch — no lost responses.
///
/// **Context cache** — per-session `.json` files holding recent message history.
/// Loaded instead of querying the Dropbox DB for context building on each request.
///
/// **Dynamic cap** — how deep we go per session scales with total cache size:
/// - Cache is sparse (< 15 MB) → store up to 300 messages/session (more depth, useful)
/// - Cache is large (≥ 15 MB)  → store up to 80 messages/session  (leaner, faster searches)
///
/// Lives entirely in ~/Library/Caches/WorldTree — never synced, never persisted to Dropbox.
actor StreamCacheManager {

    static let shared = StreamCacheManager()

    // MARK: - Paths

    private let cacheRoot: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("WorldTree")
    }()

    private var streamsDir: URL { cacheRoot.appendingPathComponent("streams") }
    private var contextDir:  URL { cacheRoot.appendingPathComponent("context") }

    // MARK: - Sizing policy

    /// Below this total → sparse cache, use long limit
    private let sparseThreshold: Int = 15 * 1_048_576  // 15 MB

    /// Max messages per session when cache is sparse (small but deep)
    private let longLimit = 300

    /// Max messages per session when cache is large (lean for speed)
    private let shortLimit = 80

    /// Hard ceiling — prune oldest files once exceeded
    private let maxCacheBytes: Int = 50 * 1_048_576    // 50 MB

    // MARK: - Open write handles

    private var handles: [String: FileHandle] = [:]

    private init() {}

    // MARK: - Directory setup

    private func ensureDirs() {
        try? FileManager.default.createDirectory(at: streamsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: contextDir,  withIntermediateDirectories: true)
    }

    // MARK: - Stream temp files

    /// Open a crash-recovery temp file for this session. Call when streaming starts.
    func openStreamFile(sessionId: String) {
        ensureDirs()
        let url = streamURL(sessionId)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handles[sessionId] = try? FileHandle(forWritingTo: url)
    }

    /// Append a token chunk. Fire-and-forget safe — the actor serialises these.
    func appendToStream(sessionId: String, chunk: String) {
        guard let handle = handles[sessionId],
              let data = chunk.data(using: .utf8) else { return }
        handle.write(data)
    }

    /// Normal completion — stream finished cleanly, nothing to recover. Delete the file.
    func closeStream(sessionId: String) {
        handles[sessionId]?.closeFile()
        handles[sessionId] = nil
        try? FileManager.default.removeItem(at: streamURL(sessionId))
    }

    /// Call on app launch. Returns content salvaged from a previous crash, keyed by sessionId.
    /// Deletes all orphaned files after reading — they've served their purpose.
    func recoverOrphanedStreams() -> [String: String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: streamsDir, includingPropertiesForKeys: nil
        ) else { return [:] }

        var recovered: [String: String] = [:]
        for url in files where url.pathExtension == "tmp" {
            let sessionId = url.deletingPathExtension().lastPathComponent
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                recovered[sessionId] = text
            }
            try? FileManager.default.removeItem(at: url)
        }
        return recovered
    }

    // MARK: - Context cache

    struct CachedMessage: Codable {
        let role: String       // "user" | "assistant" | "system"
        let content: String
        let timestamp: Date
    }

    /// Dynamic limit based on current total cache size.
    var contextMessageLimit: Int {
        dirSize(contextDir) < sparseThreshold ? longLimit : shortLimit
    }

    /// Write the most recent messages for a session to the local cache.
    func updateContextCache(sessionId: String, messages: [CachedMessage]) {
        ensureDirs()
        let trimmed = Array(messages.suffix(contextMessageLimit))
        if let data = try? JSONEncoder().encode(trimmed) {
            try? data.write(to: contextURL(sessionId), options: .atomic)
        }
        // Prune in background if over budget
        Task { pruneIfNeeded() }
    }

    /// Load cached messages for a session. Returns nil if no cache exists.
    func loadContextCache(sessionId: String) -> [CachedMessage]? {
        guard let data = try? Data(contentsOf: contextURL(sessionId)),
              let msgs = try? JSONDecoder().decode([CachedMessage].self, from: data),
              !msgs.isEmpty else { return nil }
        return msgs
    }

    // MARK: - Pruning

    private func pruneIfNeeded() {
        let total = dirSize(contextDir)
        guard total > maxCacheBytes else { return }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: contextDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        // Oldest first
        let sorted = files.compactMap { url -> (URL, Date, Int)? in
            let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let date = rv?.contentModificationDate else { return nil }
            return (url, date, rv?.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }

        let target = total - (maxCacheBytes / 2)   // prune down to 50% headroom
        var freed = 0
        for (url, _, size) in sorted {
            try? FileManager.default.removeItem(at: url)
            freed += size
            if freed >= target { break }
        }
    }

    // MARK: - Helpers

    private func streamURL(_ sessionId: String) -> URL {
        streamsDir.appendingPathComponent("\(sessionId).tmp")
    }

    private func contextURL(_ sessionId: String) -> URL {
        contextDir.appendingPathComponent("\(sessionId).json")
    }

    private func dirSize(_ dir: URL) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
