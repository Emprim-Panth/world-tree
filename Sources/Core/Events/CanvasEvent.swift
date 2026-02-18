import Foundation
import GRDB

// MARK: - Canvas Event Taxonomy

/// Structured event log for observability — every significant action in Canvas gets recorded.
/// Stored in SQLite `canvas_events` table, queryable for dashboards, timelines, and analytics.
enum CanvasEventType: String, Codable, DatabaseValueConvertible {
    case textChunk       // Streaming text received
    case toolStart       // Tool execution began
    case toolEnd         // Tool execution completed
    case toolError       // Tool execution failed
    case messageUser     // User sent a message
    case messageAssistant // Assistant response saved
    case sessionStart    // Conversation session began
    case sessionEnd      // Session completed
    case branchFork      // New branch forked
    case branchComplete  // Branch marked completed
    case error           // General error
    case tokenUsage          // Token usage snapshot
    case contextCheckpoint   // Session rotation checkpoint created
    case sessionRotation     // CLI session was rotated
    case summaryGenerated    // Branch summary was generated
}

/// A single recorded event in Canvas.
struct CanvasEvent: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "canvas_events"

    var id: Int64?
    var branchId: String
    var sessionId: String?
    var eventType: CanvasEventType
    var eventData: String?  // JSON payload for event-specific data
    var timestamp: Date

    enum CodingKeys: String, CodingKey {
        case id
        case branchId = "branch_id"
        case sessionId = "session_id"
        case eventType = "event_type"
        case eventData = "event_data"
        case timestamp
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Event Store

/// Singleton event logger backed by SQLite.
/// Thread-safe: batch writes via serial queue.
@MainActor
final class EventStore {
    static let shared = EventStore()

    /// In-memory buffer for batch writes (reduces DB pressure during streaming)
    private var buffer: [CanvasEvent] = []
    private let batchSize = 20
    private var flushTask: Task<Void, Never>?

    private init() {}

    // MARK: - Logging

    /// Record a single event (buffered, flushed periodically or at batch size).
    func log(
        branchId: String,
        sessionId: String? = nil,
        type: CanvasEventType,
        data: [String: Any]? = nil
    ) {
        let jsonData: String?
        if let data, let encoded = try? JSONSerialization.data(withJSONObject: data),
           let str = String(data: encoded, encoding: .utf8) {
            jsonData = str
        } else {
            jsonData = nil
        }

        let event = CanvasEvent(
            branchId: branchId,
            sessionId: sessionId,
            eventType: type,
            eventData: jsonData,
            timestamp: Date()
        )

        buffer.append(event)

        if buffer.count >= batchSize {
            flush()
        } else if flushTask == nil {
            // Auto-flush after 2 seconds if batch doesn't fill
            flushTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.flush()
            }
        }
    }

    /// Force write all buffered events to DB.
    func flush() {
        flushTask?.cancel()
        flushTask = nil

        guard !buffer.isEmpty else { return }
        let events = buffer
        buffer = []

        do {
            try DatabaseManager.shared.write { db in
                for var event in events {
                    try event.insert(db)
                }
            }
        } catch {
            canvasLog("[EventStore] Failed to flush \(events.count) events: \(error)")
            // Put events back to avoid silent data loss
            buffer.insert(contentsOf: events, at: 0)
        }
    }

    // MARK: - Queries

    /// Recent events for a branch (for timeline display).
    func recentEvents(branchId: String, limit: Int = 50) -> [CanvasEvent] {
        (try? DatabaseManager.shared.read { db in
            try CanvasEvent
                .filter(Column("branch_id") == branchId)
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
                .reversed()
        }) ?? []
    }

    /// Count of events in the last N minutes for a branch (activity pulse).
    func activityCount(branchId: String, minutes: Int = 5) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(minutes * 60))
        return (try? DatabaseManager.shared.read { db in
            try CanvasEvent
                .filter(Column("branch_id") == branchId)
                .filter(Column("timestamp") >= cutoff)
                .fetchCount(db)
        }) ?? 0
    }

    /// Tool execution events for timeline (toolStart + toolEnd pairs).
    func toolEvents(branchId: String, limit: Int = 100) -> [CanvasEvent] {
        (try? DatabaseManager.shared.read { db in
            try CanvasEvent
                .filter(Column("branch_id") == branchId)
                .filter([CanvasEventType.toolStart.rawValue, CanvasEventType.toolEnd.rawValue, CanvasEventType.toolError.rawValue].contains(Column("event_type")))
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
                .reversed()
        }) ?? []
    }

    /// Total event count per type for a branch (summary stats).
    func eventCounts(branchId: String) -> [CanvasEventType: Int] {
        guard let rows = try? DatabaseManager.shared.read({ db in
            try Row.fetchAll(db, sql: """
                SELECT event_type, COUNT(*) as count
                FROM canvas_events
                WHERE branch_id = ?
                GROUP BY event_type
                """, arguments: [branchId])
        }) else { return [:] }

        var result: [CanvasEventType: Int] = [:]
        for row in rows {
            if let typeStr: String = row["event_type"],
               let type = CanvasEventType(rawValue: typeStr),
               let count: Int = row["count"] {
                result[type] = count
            }
        }
        return result
    }

    /// Prune events older than N days to keep DB lean.
    func prune(olderThanDays: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays * 86400))
        do {
            try DatabaseManager.shared.write { db in
                try db.execute(
                    sql: "DELETE FROM canvas_events WHERE timestamp < ?",
                    arguments: [cutoff]
                )
            }
        } catch {
            canvasLog("[EventStore] Prune failed: \(error)")
        }
    }
}
