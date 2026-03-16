import Foundation

/// Local SSD cache for World Tree. Two layers, zero Dropbox involvement.
///
/// **Stream files** — `.tmp` files written token-by-token during a live response.
/// Auto-deleted on successful completion. If the process dies mid-stream (SIGTERM etc),
/// the file survives and is recovered on next launch — no lost responses.
///
/// **Context cache** — per-session `.json` files holding recent message history.
/// Loaded instead of querying the conversations DB for context building on each request.
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

    // MARK: - Cached message limit

    /// Cached result for contextMessageLimit to avoid scanning the directory on every access.
    /// Protected by actor isolation — all reads/writes go through the actor's serial executor.
    private var cachedMessageLimit: Int?
    private var limitLastComputed: Date?

    // MARK: - Open write handles

    private var handles: [String: FileHandle] = [:]

    /// Track chunks written per handle for periodic fsync
    private var chunkCounts: [String: Int] = [:]

    /// Track last write time per handle for stale cleanup
    private var lastWriteTime: [String: Date] = [:]

    /// How often (in chunks) to call synchronizeFile()
    private let fsyncInterval = 20

    /// Handles unused for longer than this are considered stale.
    /// Tool-heavy turns can legitimately go quiet for several minutes while work happens
    /// off-token, so keep the recovery file alive long enough to survive background runs.
    private let staleHandleTimeout: TimeInterval = 30 * 60  // 30 minutes

    /// Whether the stale-handle cleanup task is running
    private var cleanupTaskRunning = false

    private init() {}

    // MARK: - Directory setup

    private func ensureDirs() {
        do {
            try FileManager.default.createDirectory(at: streamsDir, withIntermediateDirectories: true)
        } catch {
            wtLog("[StreamCache] Failed to create streams dir: \(error)")
        }
        do {
            try FileManager.default.createDirectory(at: contextDir, withIntermediateDirectories: true)
        } catch {
            wtLog("[StreamCache] Failed to create context dir: \(error)")
        }
    }

    // MARK: - Stream temp files

    /// Open a crash-recovery temp file for this session. Call when streaming starts.
    func openStreamFile(sessionId: String) {
        _ = ensureHandle(for: sessionId)
        startStaleHandleCleanupIfNeeded()
    }

    /// Append a token chunk. Fire-and-forget safe — the actor serialises these.
    /// Calls synchronizeFile() every `fsyncInterval` chunks to ensure data reaches disk.
    func appendToStream(sessionId: String, chunk: String) {
        guard let data = chunk.data(using: .utf8),
              let handle = ensureHandle(for: sessionId) else { return }
        do {
            try handle.write(contentsOf: data)
            lastWriteTime[sessionId] = Date()

            let count = (chunkCounts[sessionId] ?? 0) + 1
            chunkCounts[sessionId] = count

            // Periodic fsync so crash doesn't lose buffered writes
            if count % fsyncInterval == 0 {
                handle.synchronizeFile()
            }
        } catch {
            wtLog("[StreamCache] Write failed for \(sessionId): \(error) — closing handle")
            try? handle.close()
            handles[sessionId] = nil
            chunkCounts[sessionId] = nil
            lastWriteTime[sessionId] = nil
        }
    }

    /// Refresh the recovery file's liveness without appending text.
    /// Used for tool/thinking events so long-running background work stays recoverable.
    func touchStream(sessionId: String) {
        guard ensureHandle(for: sessionId) != nil else { return }
        lastWriteTime[sessionId] = Date()
    }

    /// Returns all session IDs with currently open write handles.
    func openSessionIds() -> [String] { Array(handles.keys) }

    /// Clean shutdown — close all open handles and delete their files so they are not
    /// mistaken for crash-interrupted streams on the next launch.
    /// Only call from willTerminateNotification, not from mid-stream cancellations.
    func closeAllStreams() {
        let openIds = Array(handles.keys)
        for sessionId in openIds {
            closeStream(sessionId: sessionId)
        }
    }

    /// Normal completion — stream finished cleanly, nothing to recover. Delete the file.
    func closeStream(sessionId: String) {
        if let handle = handles[sessionId] {
            // Final fsync before close to flush any remaining buffered data
            handle.synchronizeFile()
            handle.closeFile()
        }
        handles[sessionId] = nil
        chunkCounts[sessionId] = nil
        lastWriteTime[sessionId] = nil
        try? FileManager.default.removeItem(at: streamURL(sessionId))
    }

    /// Call on app launch. Returns every orphaned stream keyed by sessionId.
    /// Empty content is still meaningful: it indicates a quiet tool/thinking run that should
    /// be auto-resumed even though there are no assistant tokens to restore yet.
    /// Deletes all orphaned files after reading — they've served their purpose.
    func recoverOrphanedStreams() -> [String: String] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: streamsDir, includingPropertiesForKeys: nil
            )
        } catch {
            wtLog("[StreamCache] Failed to scan streams dir for recovery: \(error)")
            return [:]
        }

        var recovered: [String: String] = [:]
        for url in files where url.pathExtension == "tmp" {
            // Strip legacy "session-" prefix written by older app versions.
            // These files have names like "session-<UUID>.tmp" but the recovery
            // store and coordinator expect bare UUIDs.
            var sessionId = url.deletingPathExtension().lastPathComponent
            if sessionId.hasPrefix("session-") {
                sessionId = String(sessionId.dropFirst("session-".count))
                wtLog("[StreamCache] Stripped legacy 'session-' prefix from stream file: \(url.lastPathComponent)")
            }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                recovered[sessionId] = text
            } catch {
                wtLog("[StreamCache] Failed to read orphaned stream \(sessionId.prefix(8)): \(error)")
                recovered[sessionId] = ""  // Still signal that recovery is needed
            }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                wtLog("[StreamCache] Failed to delete recovered stream file \(sessionId.prefix(8)): \(error)")
            }
        }
        return recovered
    }

    // MARK: - Stale handle cleanup

    /// Launches a repeating background task that scans for stale handles every 60 seconds.
    /// Runs only while there are open handles; stops automatically when all are closed.
    private func startStaleHandleCleanupIfNeeded() {
        guard !cleanupTaskRunning else { return }
        cleanupTaskRunning = true
        Task {
            while true {
                try? await Task.sleep(for: .seconds(60))
                await self.reapStaleHandles()
                if await self.handles.isEmpty {
                    await self.markCleanupStopped()
                    break
                }
            }
        }
    }

    /// Close any handle that hasn't been written to within `staleHandleTimeout`.
    private func reapStaleHandles() {
        let now = Date()
        for (sessionId, lastWrite) in lastWriteTime {
            if now.timeIntervalSince(lastWrite) > staleHandleTimeout {
                wtLog("[StreamCache] Reaping stale handle for \(sessionId) — idle \(Int(now.timeIntervalSince(lastWrite)))s")
                if let handle = handles[sessionId] {
                    handle.synchronizeFile()
                    handle.closeFile()
                }
                handles[sessionId] = nil
                chunkCounts[sessionId] = nil
                lastWriteTime[sessionId] = nil
                // Leave the .tmp file on disk — recoverOrphanedStreams() will pick it up
            }
        }
    }

    private func markCleanupStopped() {
        cleanupTaskRunning = false
    }

    // MARK: - Context cache

    struct CachedMessage: Codable {
        let role: String       // "user" | "assistant" | "system"
        let content: String
        let timestamp: Date
    }

    /// Dynamic limit based on current total cache size.
    /// Cached for 60 seconds to avoid scanning the directory on every access.
    var contextMessageLimit: Int {
        let now = Date()
        if let cached = cachedMessageLimit,
           let lastComputed = limitLastComputed,
           now.timeIntervalSince(lastComputed) < 60 {
            return cached
        }
        let limit = dirSize(contextDir) < sparseThreshold ? longLimit : shortLimit
        cachedMessageLimit = limit
        limitLastComputed = now
        return limit
    }

    /// Write the most recent messages for a session to the local cache.
    func updateContextCache(sessionId: String, messages: [CachedMessage]) {
        ensureDirs()
        let trimmed = Array(messages.suffix(contextMessageLimit))
        do {
            let data = try JSONEncoder().encode(trimmed)
            try data.write(to: contextURL(sessionId), options: .atomic)
        } catch {
            wtLog("[StreamCache] Failed to write context cache for \(sessionId.prefix(8)): \(error)")
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

    private func ensureHandle(for sessionId: String) -> FileHandle? {
        if let existing = handles[sessionId] { return existing }

        ensureDirs()
        let url = streamURL(sessionId)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            handles[sessionId] = handle
            chunkCounts[sessionId] = chunkCounts[sessionId] ?? 0
            lastWriteTime[sessionId] = Date()
            return handle
        } catch {
            wtLog("[StreamCache] Failed to open write handle for \(sessionId.prefix(8)): \(error)")
            return nil
        }
    }
}
