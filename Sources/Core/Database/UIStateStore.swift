import Foundation
import GRDB

// MARK: - UI State Store

/// Key-value persistence for Command Center layout state.
/// Uses the `ui_state` table (created in migration v24).
/// All operations are fire-and-forget — UI never blocks on state persistence.
@MainActor
final class UIStateStore {
    static let shared = UIStateStore()

    /// In-memory cache to avoid DB reads on every access.
    private var cache: [String: String] = [:]
    private var loaded = false

    private init() {}

    // MARK: - Load

    func loadAll() {
        guard !loaded else { return }
        do {
            let rows = try DatabaseManager.shared.read { db -> [Row] in
                guard try db.tableExists("ui_state") else { return [] }
                return try Row.fetchAll(db, sql: "SELECT key, value FROM ui_state")
            }
            for row in rows {
                if let key: String = row["key"], let value: String = row["value"] {
                    cache[key] = value
                }
            }
            loaded = true
        } catch {
            wtLog("[UIStateStore] Failed to load state: \(error)")
        }
    }

    // MARK: - Accessors

    func get(_ key: String) -> String? {
        loadAll()
        return cache[key]
    }

    func getBool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let value = get(key) else { return defaultValue }
        return value == "true" || value == "1"
    }

    func getInt(_ key: String, default defaultValue: Int = 0) -> Int {
        guard let value = get(key) else { return defaultValue }
        return Int(value) ?? defaultValue
    }

    // MARK: - Mutators

    func set(_ key: String, value: String) {
        cache[key] = value
        persistAsync(key: key, value: value)
    }

    func setBool(_ key: String, value: Bool) {
        set(key, value: value ? "true" : "false")
    }

    func setInt(_ key: String, value: Int) {
        set(key, value: String(value))
    }

    func remove(_ key: String) {
        cache.removeValue(forKey: key)
        Task {
            try? DatabaseManager.shared.write { db in
                try db.execute(sql: "DELETE FROM ui_state WHERE key = ?", arguments: [key])
            }
        }
    }

    // MARK: - Async Persistence

    private func persistAsync(key: String, value: String) {
        Task {
            do {
                try DatabaseManager.shared.write { db in
                    try db.execute(sql: """
                        INSERT INTO ui_state (key, value, updated_at)
                        VALUES (?, ?, datetime('now'))
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                        """, arguments: [key, value])
                }
            } catch {
                wtLog("[UIStateStore] Failed to persist \(key): \(error)")
            }
        }
    }
}

// MARK: - State Keys

extension UIStateStore {
    enum Key {
        static let agentsExpanded = "cc.section.agents.expanded"
        static let tokensExpanded = "cc.section.tokens.expanded"
        static let crewExpanded = "cc.section.crew.expanded"
        static let recentExpanded = "cc.section.recent.expanded"
        static let streamsExpanded = "cc.section.streams.expanded"
        static let filterProject = "cc.filter.project"
        static let filterAgent = "cc.filter.agent"
        static let watchedSessions = "cc.watched.sessions"
        static let layoutColumns = "cc.layout.columns"
    }
}
