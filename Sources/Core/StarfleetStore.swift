import Foundation
import GRDB
import Observation

/// Manages the Starfleet crew roster and activity.
///
/// Crew data is loaded from `crew_registry` (v42 migration) — the single source of truth
/// for the org chart, seeded from CONSTITUTION.md. Never use a hardcoded roster here.
/// Activity is overlaid from `starfleet_activity` events logged by the harness.
@MainActor
@Observable
final class StarfleetStore {
    static let shared = StarfleetStore()

    private(set) var crewRegistry: [CrewMember] = []
    private(set) var crewActivity: [String: CrewMember] = [:]
    private(set) var recentEvents: [ActivityEvent] = []

    // MARK: - Models

    struct CrewMember: Identifiable {
        let id: String
        let name: String
        let role: String
        let gameDevRole: String?
        let department: String    // "command" | "coding" | "game-dev"
        let tier: Int
        let icon: String
        let lastEvent: String?
        let lastProject: String?
        let lastSeen: Date?
        let eventCount: Int

        var isActive: Bool { lastEvent == "start" || lastEvent == "dispatch" }

        /// Role label to display given the selected department context.
        func displayRole(for dept: Department) -> String {
            if dept == .gameDev, let gdRole = gameDevRole { return gdRole }
            return role
        }
    }

    struct ActivityEvent: Identifiable {
        let id: Int64
        let agentName: String
        let eventType: String
        let project: String?
        let detail: String?
        let createdAt: Date?
    }

    enum Department: String, CaseIterable {
        case all      = "All"
        case coding   = "Coding"
        case gameDev  = "Game Dev"
    }

    // MARK: - Icon Mapping (SF Symbols, keyed by crew name)

    private static let iconMap: [String: String] = [
        "Cortana":   "shield.checkered",
        "Picard":    "star.circle.fill",
        "Spock":     "brain",
        "Geordi":    "wrench.and.screwdriver",
        "Torres":    "gauge.with.needle",
        "Data":      "paintpalette",
        "Worf":      "shield.lefthalf.filled",
        "Dax":       "link.circle",
        "Scotty":    "hammer",
        "Uhura":     "text.bubble",
        "Troi":      "person.wave.2",
        "Quark":     "chart.bar.xaxis",
        "Chief":     "lock.shield",
        "Keyes":     "chart.xyaxis.line",
        "Roland":    "doc.text.magnifyingglass",
        "Halsey":    "testtube.2",
        "Bashir":    "stethoscope",
        "Garak":     "eye.trianglebadge.exclamationmark",
        "Q":         "questionmark.circle",
        "Seven":     "magnifyingglass.circle",
        "Kim":       "doc.text",
        "Composer":  "music.note",
        "Nog":       "cylinder.split.1x2",
        "O'Brien":   "arrow.triangle.2.circlepath",
        "Odo":       "lock.shield.fill",
        "Paris":     "map",
        "Sato":      "globe",
        "Zimmerman": "ant.circle",
    ]

    static func icon(for name: String) -> String {
        iconMap[name] ?? "person.circle"
    }

    private init() {}

    // MARK: - Refresh

    func refresh() {
        loadCrewFromRegistry()
        loadCrewActivity()
        loadRecentEvents()
    }

    // MARK: - Load crew_registry (authoritative org chart)

    private func loadCrewFromRegistry() {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }

        do {
            let rows = try dbPool.read { db -> [Row] in
                guard try db.tableExists("crew_registry") else { return [] }
                return try Row.fetchAll(db, sql: """
                    SELECT id, name, role, department, tier, game_dev_role
                    FROM crew_registry
                    ORDER BY tier ASC, name ASC
                """)
            }

            crewRegistry = rows.map { row in
                let name: String = row["name"] ?? "Unknown"
                return CrewMember(
                    id: row["id"] ?? name.lowercased(),
                    name: name,
                    role: row["role"] ?? "General",
                    gameDevRole: row["game_dev_role"],
                    department: row["department"] ?? "coding",
                    tier: row["tier"] ?? 4,
                    icon: Self.icon(for: name),
                    lastEvent: nil, lastProject: nil, lastSeen: nil, eventCount: 0
                )
            }
        } catch {
            wtLog("[StarfleetStore] Failed to load crew registry: \(error)")
        }
    }

    // MARK: - Overlay activity data on top of registry

    private func loadCrewActivity() {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        // Seed from registry first so all crew appear even with no activity
        var activity: [String: CrewMember] = [:]
        for member in crewRegistry {
            activity[member.name] = member
        }

        do {
            let rows = try dbPool.read { db -> [Row] in
                guard try db.tableExists("starfleet_activity") else { return [] }
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

            for row in rows {
                let name: String = row["agent_name"] ?? "Unknown"
                let lastSeenStr: String? = row["last_seen"]
                let base = activity[name]
                activity[name] = CrewMember(
                    id: base?.id ?? name.lowercased(),
                    name: name,
                    role: base?.role ?? "General",
                    gameDevRole: base?.gameDevRole,
                    department: base?.department ?? "coding",
                    tier: base?.tier ?? 4,
                    icon: base?.icon ?? Self.icon(for: name),
                    lastEvent: row["last_event"],
                    lastProject: row["last_project"],
                    lastSeen: lastSeenStr.flatMap { dateFormatter.date(from: $0) },
                    eventCount: row["event_count"] ?? 0
                )
            }

            crewActivity = activity
        } catch {
            wtLog("[StarfleetStore] Failed to load crew activity: \(error)")
        }
    }

    // MARK: - Recent events

    private func loadRecentEvents() {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        do {
            let rows = try dbPool.read { db -> [Row] in
                guard try db.tableExists("starfleet_activity") else { return [] }
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
