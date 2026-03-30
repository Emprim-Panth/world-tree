import Foundation
import GRDB
import Observation

/// Reads today's briefing from ~/.cortana/briefings/ and active alerts from cortana_alerts table.
@MainActor
@Observable
final class BriefingStore {
    static let shared = BriefingStore()

    private(set) var todayBriefing: String?
    private(set) var briefingDate: Date?
    private(set) var activeAlerts: [Alert] = []
    private(set) var alertCounts: (info: Int, warning: Int, critical: Int) = (0, 0, 0)

    private let fm = FileManager.default
    private let briefingsDir: String
    private let alertsDir: String

    struct Alert: Identifiable {
        let id: String
        let type: String
        let project: String?
        let message: String
        let severity: String
        let source: String
        let createdAt: Date?

        var severityIcon: String {
            switch severity {
            case "critical": return "exclamationmark.triangle.fill"
            case "warning": return "exclamationmark.circle.fill"
            default: return "info.circle.fill"
            }
        }

        var severityColor: String {
            switch severity {
            case "critical": return "red"
            case "warning": return "orange"
            default: return "blue"
            }
        }
    }

    private init() {
        let home = fm.homeDirectoryForCurrentUser.path
        briefingsDir = "\(home)/.cortana/briefings"
        alertsDir = "\(home)/.cortana/alerts"
    }

    // MARK: - Refresh

    func refresh() {
        loadTodayBriefing()
        loadActiveAlerts()
    }

    // MARK: - Briefing

    private func loadTodayBriefing() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let path = "\(briefingsDir)/\(today).md"

        if fm.fileExists(atPath: path) {
            do {
                todayBriefing = try String(contentsOfFile: path, encoding: .utf8)
                briefingDate = Date()
            } catch {
                wtLog("[BriefingStore] Failed to read briefing: \(error)")
            }
        } else {
            // Check for most recent briefing
            todayBriefing = loadMostRecentBriefing()
        }
    }

    private func loadMostRecentBriefing() -> String? {
        guard let files = try? fm.contentsOfDirectory(atPath: briefingsDir) else { return nil }
        let mdFiles = files.filter { $0.hasSuffix(".md") }.sorted().reversed()
        guard let latest = mdFiles.first else { return nil }

        let path = "\(briefingsDir)/\(latest)"
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            briefingDate = formatter.date(from: String(latest.dropLast(3)))
            return content
        } catch {
            wtLog("[BriefingStore] Failed to read latest briefing: \(error)")
            return nil
        }
    }

    // MARK: - Alerts (from DB)

    private func loadActiveAlerts() {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }

        do {
            let rows = try dbPool.read { db in
                guard try db.tableExists("cortana_alerts") else { return [Row]() }
                return try Row.fetchAll(db, sql: """
                    SELECT id, type, project, message, severity, source, created_at
                    FROM cortana_alerts
                    WHERE resolved = 0
                    ORDER BY
                        CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END,
                        created_at DESC
                    LIMIT 50
                """)
            }

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

            activeAlerts = rows.map { row in
                let dateStr: String? = row["created_at"]
                return Alert(
                    id: row["id"] ?? UUID().uuidString,
                    type: row["type"] ?? "unknown",
                    project: row["project"],
                    message: row["message"] ?? "",
                    severity: row["severity"] ?? "info",
                    source: row["source"] ?? "manual",
                    createdAt: dateStr.flatMap { dateFormatter.date(from: $0) }
                )
            }

            let critCount = activeAlerts.filter { $0.severity == "critical" }.count
            let warnCount = activeAlerts.filter { $0.severity == "warning" }.count
            let infoCount = activeAlerts.filter { $0.severity == "info" }.count
            alertCounts = (info: infoCount, warning: warnCount, critical: critCount)
        } catch {
            wtLog("[BriefingStore] Failed to load alerts: \(error)")
        }
    }

    // MARK: - Alert file loading (for scheduled agent output)

    func loadFileAlerts() -> [String] {
        guard let files = try? fm.contentsOfDirectory(atPath: alertsDir) else { return [] }
        return files.filter { $0.hasSuffix(".md") || $0.hasSuffix(".txt") }.compactMap { file in
            try? String(contentsOfFile: "\(alertsDir)/\(file)", encoding: .utf8)
        }
    }

    // MARK: - Resolve

    func resolveAlert(id: String) {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }
        do {
            try dbPool.write { db in
                try db.execute(
                    sql: "UPDATE cortana_alerts SET resolved = 1, resolved_at = datetime('now') WHERE id = ?",
                    arguments: [id]
                )
            }
            loadActiveAlerts()
        } catch {
            wtLog("[BriefingStore] Failed to resolve alert \(id): \(error)")
        }
    }
}
