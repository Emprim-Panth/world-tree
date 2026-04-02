import Foundation
import GRDB
import os.log

private let scratchLog = Logger(subsystem: "com.forgeandcode.WorldTree", category: "Scratchpad")

/// Reads scratchpad entries from the shared conversations.db.
/// Provides observable arrays for the Scratchpad View.
@MainActor
@Observable
final class ScratchpadStore {
    static let shared = ScratchpadStore()

    // MARK: — Observable State

    var entries: [ScratchpadEntry] = []
    var filterProject: String?
    var filterType: String?
    var lastUpdate: Date?

    var projects: [String] {
        Array(Set(entries.map(\.project))).sorted()
    }

    var activeCount: Int { entries.count }

    var byType: [String: Int] {
        var counts: [String: Int] = [:]
        for e in entries { counts[e.entryType, default: 0] += 1 }
        return counts
    }

    // MARK: — Internal

    private var pollTimer: Timer?

    private init() {}

    // MARK: — Lifecycle

    func start() {
        refresh()
        // Poll every 5 seconds for new entries
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: — Data

    func refresh() {
        do {
            let rows = try DatabaseManager.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, project, topic, agent, session_id, entry_type, content,
                           promoted, promoted_to, created_at, expires_at
                    FROM scratchpad
                    WHERE expires_at > datetime('now') AND promoted = 0
                    ORDER BY created_at DESC
                    LIMIT 100
                """)
            }

            var parsed: [ScratchpadEntry] = []
            for row in rows {
                parsed.append(ScratchpadEntry(
                    id: row["id"] as? String ?? "",
                    project: row["project"] as? String ?? "",
                    topic: row["topic"] as? String ?? "",
                    agent: row["agent"] as? String ?? "cortana",
                    sessionId: row["session_id"] as? String ?? "",
                    entryType: row["entry_type"] as? String ?? "finding",
                    content: row["content"] as? String ?? "",
                    promoted: (row["promoted"] as? Int ?? 0) == 1,
                    promotedTo: row["promoted_to"] as? String,
                    createdAt: row["created_at"] as? String ?? "",
                    expiresAt: row["expires_at"] as? String ?? ""
                ))
            }

            // Apply filters
            var filtered = parsed
            if let filterProject, !filterProject.isEmpty {
                filtered = filtered.filter { $0.project == filterProject }
            }
            if let filterType, !filterType.isEmpty {
                filtered = filtered.filter { $0.entryType == filterType }
            }

            entries = filtered
            lastUpdate = Date()
        } catch {
            scratchLog.error("Failed to read scratchpad: \(error.localizedDescription)")
        }
    }
}

// MARK: — Model

struct ScratchpadEntry: Identifiable, Hashable {
    let id: String
    let project: String
    let topic: String
    let agent: String
    let sessionId: String
    let entryType: String
    let content: String
    let promoted: Bool
    let promotedTo: String?
    let createdAt: String
    let expiresAt: String

    var typeIcon: String {
        switch entryType {
        case "finding": return "magnifyingglass"
        case "decision": return "diamond.fill"
        case "blocker": return "exclamationmark.octagon.fill"
        case "handoff": return "arrow.right.circle.fill"
        default: return "circle"
        }
    }

    var relativeTime: String {
        // Try sqlite datetime format first (most common from scratchpad)
        let sqlFormatter = DateFormatter()
        sqlFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        sqlFormatter.timeZone = TimeZone(identifier: "UTC")

        let date: Date? = sqlFormatter.date(from: createdAt) ?? {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return isoFormatter.date(from: createdAt)
        }()

        guard let date else { return createdAt }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}
