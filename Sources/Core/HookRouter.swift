import Foundation
import GRDB
import Observation

/// Routes hook events from the shared hook_events table to specific sessions by session_id.
@MainActor
@Observable
final class HookRouter {
    static let shared = HookRouter()

    /// Recent hook events per session, keyed by session_id.
    private(set) var sessionEvents: [String: [HookEvent]] = [:]

    /// Most recent tool use per session.
    private(set) var lastToolUse: [String: HookEvent] = [:]

    private var pollTask: Task<Void, Never>?
    private var lastPollDate: Date = Date()

    struct HookEvent: Identifiable, Sendable {
        let id: Int64
        let hookType: String
        let sessionId: String?
        let project: String?
        let payload: String?
        let createdAt: Date?

        var toolName: String? {
            guard hookType == "PostToolUse" || hookType == "PreToolUse",
                  let payload, let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["tool_name"] as? String
        }
    }

    private init() {}

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await pollEvents()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollEvents() async {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let since = formatter.string(from: lastPollDate)

        do {
            let rows = try await dbPool.read { db in
                guard try db.tableExists("hook_events") else { return [Row]() }
                return try Row.fetchAll(db, sql: """
                    SELECT id, hook_type, session_id, project, payload, created_at
                    FROM hook_events
                    WHERE created_at > ?
                    ORDER BY created_at ASC
                    LIMIT 100
                """, arguments: [since])
            }

            for row in rows {
                let dateStr: String? = row["created_at"]
                let event = HookEvent(
                    id: row["id"] ?? 0,
                    hookType: row["hook_type"] ?? "",
                    sessionId: row["session_id"],
                    project: row["project"],
                    payload: row["payload"],
                    createdAt: dateStr.flatMap { DateParsing.parse($0) }
                )

                if let sid = event.sessionId {
                    sessionEvents[sid, default: []].append(event)
                    // Keep only last 50 events per session
                    if sessionEvents[sid]!.count > 50 {
                        sessionEvents[sid] = Array(sessionEvents[sid]!.suffix(50))
                    }

                    if event.hookType == "PostToolUse" {
                        lastToolUse[sid] = event
                    }
                }
            }

            lastPollDate = Date()
        } catch {
            wtLog("[HookRouter] Failed to poll events: \(error)")
        }
    }

    func events(for sessionId: String) -> [HookEvent] {
        sessionEvents[sessionId] ?? []
    }
}
