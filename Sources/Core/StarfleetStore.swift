import Foundation
import GRDB
import Observation

/// Manages the Starfleet crew roster and activity from starfleet_activity table.
@MainActor
@Observable
final class StarfleetStore {
    static let shared = StarfleetStore()

    private(set) var crewActivity: [String: CrewMember] = [:]
    private(set) var recentEvents: [ActivityEvent] = []

    struct CrewMember: Identifiable {
        let id: String  // agent name
        let name: String
        let specialization: String
        let icon: String
        let lastEvent: String?
        let lastProject: String?
        let lastSeen: Date?
        let eventCount: Int
        var isActive: Bool { lastEvent == "start" || lastEvent == "dispatch" }
    }

    struct ActivityEvent: Identifiable {
        let id: Int64
        let agentName: String
        let eventType: String
        let project: String?
        let detail: String?
        let createdAt: Date?
    }

    // MARK: - Roster (static crew definition)

    static let roster: [(name: String, specialization: String, icon: String)] = [
        ("Cortana", "Orchestration, persona, session context", "shield.checkered"),
        ("Geordi", "DB migrations, GRDB patterns, TCC/CDHash", "wrench.and.screwdriver"),
        ("Torres", "Stream recovery, token tracking, performance", "gauge.with.needle"),
        ("Data", "Design verification, component tokens", "paintpalette"),
        ("Worf", "QA gates, crash reproduction, integrity", "shield.lefthalf.filled"),
        ("Spock", "Strategic planning, architecture", "brain"),
        ("Scotty", "Implementation, build systems", "hammer"),
        ("Friday", "Mobile, iOS development", "iphone"),
        ("Chief", "Security operations, secret scanning, cert monitoring", "lock.shield"),
        ("Keyes", "Revenue analytics, velocity metrics, cost tracking", "chart.bar.xaxis"),
        ("Roland", "Log intelligence, anomaly detection, error patterns", "doc.text.magnifyingglass"),
        ("Halsey", "Test automation, regression suites, coverage tracking", "testtube.2"),
    ]

    private init() {}

    // MARK: - Refresh

    func refresh() {
        loadCrewActivity()
        loadRecentEvents()
    }

    private func loadCrewActivity() {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        do {
            let rows = try dbPool.read { db in
                guard try db.tableExists("starfleet_activity") else { return [Row]() }
                return try Row.fetchAll(db, sql: """
                    SELECT agent_name,
                           (SELECT event_type FROM starfleet_activity s2
                            WHERE s2.agent_name = s1.agent_name
                            ORDER BY created_at DESC LIMIT 1) as last_event,
                           (SELECT project FROM starfleet_activity s3
                            WHERE s3.agent_name = s1.agent_name AND s3.project IS NOT NULL
                            ORDER BY created_at DESC LIMIT 1) as last_project,
                           MAX(created_at) as last_seen,
                           COUNT(*) as event_count
                    FROM starfleet_activity s1
                    GROUP BY agent_name
                    ORDER BY MAX(created_at) DESC
                """)
            }

            var activity: [String: CrewMember] = [:]

            // Start with roster defaults
            for member in Self.roster {
                activity[member.name] = CrewMember(
                    id: member.name, name: member.name,
                    specialization: member.specialization, icon: member.icon,
                    lastEvent: nil, lastProject: nil, lastSeen: nil, eventCount: 0
                )
            }

            // Overlay with DB data
            for row in rows {
                let name: String = row["agent_name"] ?? "Unknown"
                let lastEvent: String? = row["last_event"]
                let lastProject: String? = row["last_project"]
                let lastSeenStr: String? = row["last_seen"]
                let eventCount: Int = row["event_count"] ?? 0

                let rosterEntry = Self.roster.first { $0.name.lowercased() == name.lowercased() }
                activity[name] = CrewMember(
                    id: name, name: name,
                    specialization: rosterEntry?.specialization ?? "General",
                    icon: rosterEntry?.icon ?? "person.circle",
                    lastEvent: lastEvent, lastProject: lastProject,
                    lastSeen: lastSeenStr.flatMap { dateFormatter.date(from: $0) },
                    eventCount: eventCount
                )
            }

            crewActivity = activity
        } catch {
            wtLog("[StarfleetStore] Failed to load crew activity: \(error)")
        }
    }

    private func loadRecentEvents() {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        do {
            let rows = try dbPool.read { db in
                guard try db.tableExists("starfleet_activity") else { return [Row]() }
                return try Row.fetchAll(db, sql: """
                    SELECT id, agent_name, event_type, project, detail, created_at
                    FROM starfleet_activity
                    ORDER BY created_at DESC
                    LIMIT 30
                """)
            }

            recentEvents = rows.map { row in
                let dateStr: String? = row["created_at"]
                return ActivityEvent(
                    id: row["id"] ?? 0,
                    agentName: row["agent_name"] ?? "Unknown",
                    eventType: row["event_type"] ?? "unknown",
                    project: row["project"],
                    detail: row["detail"],
                    createdAt: dateStr.flatMap { dateFormatter.date(from: $0) }
                )
            }
        } catch {
            wtLog("[StarfleetStore] Failed to load recent events: \(error)")
        }
    }
}
