import Foundation
import GRDB

/// Singleton database manager for conversations.db
/// Matches cortana-core PRAGMA configuration exactly:
/// - WAL mode for concurrent read/write
/// - Foreign keys enabled
/// - 5 second busy timeout
///
/// SAFETY: WAL mode with Dropbox sync requires careful handling.
/// Dropbox syncs each file independently — the -wal and -shm files can
/// become stale relative to the main DB, risking SIGBUS on mmap.
/// Mitigations: aggressive checkpointing + synchronous=NORMAL.
@MainActor
final class DatabaseManager {
    static let shared = DatabaseManager()

    private(set) var dbPool: DatabasePool?

    /// WAL checkpoint timer — runs every 30 seconds to keep WAL size bounded
    /// and minimize risk of stale WAL files on Dropbox.
    private var checkpointTimer: Timer?

    private init() {}

    /// Opens the database at the configured path (Dropbox-synced, with fallback)
    func setup() throws {
        let path = resolveDatabasePath()

        var config = Configuration()
        config.prepareDatabase { db in
            // Match cortana-core/src/db/index.ts exactly
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            // Checkpoint after every 100 pages (~400KB) instead of 1000 (~4MB)
            // to keep WAL small — critical for Dropbox sync safety
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 100")
            // NORMAL sync is safe with WAL mode and significantly reduces
            // I/O overhead vs FULL. Data is still durable (WAL protects against corruption).
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        dbPool = try DatabasePool(path: path, configuration: config)

        // Run canvas-specific migrations
        try MigrationManager.migrate(dbPool!)

        // Start periodic WAL checkpoint to keep file size bounded
        startCheckpointTimer()
    }

    /// Resolves database path — priority order:
    /// 1. User override from Settings (UserDefaults "databasePath") if the file exists
    /// 2. Dropbox-synced path (default)
    /// 3. Local fallback (~/.cortana/cortana.db)
    private func resolveDatabasePath() -> String {
        // User-configured override (Settings → Connection tab)
        if let override = UserDefaults.standard.string(forKey: "databasePath"),
           !override.isEmpty,
           FileManager.default.fileExists(atPath: override) {
            return override
        }

        let dropboxPath = AppConstants.dropboxDatabasePath
        if FileManager.default.fileExists(atPath: dropboxPath) {
            return dropboxPath
        }

        // Dropbox not available — fall back to cortana.db
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = "\(home)/.cortana/cortana.db"
        if FileManager.default.fileExists(atPath: fallback) {
            return fallback
        }

        // Neither exists — create at Dropbox path (GRDB will create the file)
        let dir = (dropboxPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        return dropboxPath
    }

    /// Read-only access (preferred for browsing)
    func read<T>(_ block: (Database) throws -> T) throws -> T {
        guard let dbPool else { throw DatabaseError.notConnected }
        return try dbPool.read(block)
    }

    /// Read-write access (for mutations)
    func write<T>(_ block: (Database) throws -> T) throws -> T {
        guard let dbPool else { throw DatabaseError.notConnected }
        return try dbPool.write(block)
    }

    /// Async read — runs on GRDB's reader queue, NOT on MainActor.
    /// Use this for expensive queries to avoid blocking the main thread.
    func asyncRead<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        guard let dbPool else { throw DatabaseError.notConnected }
        return try await dbPool.read(block)
    }

    /// Async write — runs on GRDB's writer queue, NOT on MainActor.
    func asyncWrite<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        guard let dbPool else { throw DatabaseError.notConnected }
        return try await dbPool.write(block)
    }

    // MARK: - WAL Checkpoint Management

    /// Periodically checkpoint WAL to keep file size bounded.
    /// Critical for Dropbox sync — large WAL files are more likely to
    /// cause stale-mmap SIGBUS when synced independently of the main DB.
    private func startCheckpointTimer() {
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performCheckpoint()
            }
        }
    }

    private func performCheckpoint() {
        guard let dbPool else { return }
        do {
            try dbPool.write { db in
                // PASSIVE checkpoint — does not block readers/writers.
                // Moves committed WAL pages back to the main database file.
                try db.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)")
            }
        } catch {
            wtLog("[DatabaseManager] WAL checkpoint failed: \(error)")
        }
    }

    func stopCheckpointTimer() {
        checkpointTimer?.invalidate()
        checkpointTimer = nil
    }
}

enum DatabaseError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Database not connected. Call DatabaseManager.setup() first."
        }
    }
}
