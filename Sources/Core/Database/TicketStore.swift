import Foundation
import GRDB

// MARK: - Ticket Model

struct Ticket: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "canvas_tickets"

    let id: String              // "TASK-261"
    let project: String
    var title: String
    var description: String?
    var status: String          // pending, in_progress, review, blocked, done, cancelled
    var priority: String        // critical, high, medium, low
    var assignee: String?
    var sprint: String?
    var filePath: String?       // source TASK-*.md path
    var acceptanceCriteria: String? // JSON array
    var blockers: String?       // JSON array
    var createdAt: String?
    var updatedAt: String?
    var lastScanned: String?

    enum CodingKeys: String, CodingKey {
        case id, project, title, description, status, priority, assignee, sprint
        case filePath = "file_path"
        case acceptanceCriteria = "acceptance_criteria"
        case blockers
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastScanned = "last_scanned"
    }

    // MARK: - Computed

    var isOpen: Bool {
        status != "done" && status != "cancelled"
    }

    var isBlocked: Bool {
        status == "blocked"
    }

    var priorityOrder: Int {
        switch priority {
        case "critical": return 0
        case "high": return 1
        case "medium": return 2
        case "low": return 3
        default: return 4
        }
    }

    var statusIcon: String {
        switch status {
        case "done": return "checkmark.circle.fill"
        case "in_progress": return "play.circle.fill"
        case "blocked": return "exclamationmark.triangle.fill"
        case "review": return "eye.circle.fill"
        case "cancelled": return "xmark.circle.fill"
        default: return "circle"
        }
    }

    var statusColor: String {
        switch status {
        case "done": return "green"
        case "in_progress": return "blue"
        case "blocked": return "red"
        case "review": return "purple"
        case "cancelled": return "gray"
        default: return "secondary"
        }
    }

    var priorityColor: String {
        switch priority {
        case "critical": return "red"
        case "high": return "orange"
        case "medium": return "yellow"
        case "low": return "gray"
        default: return "secondary"
        }
    }

    var criteriaList: [String] {
        guard let raw = acceptanceCriteria else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
    }

    var blockerList: [String] {
        guard let raw = blockers else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
    }
}

// MARK: - Ticket Store

@MainActor
final class TicketStore: ObservableObject {
    static let shared = TicketStore()

    @Published private(set) var tickets: [String: [Ticket]] = [:] // project → tickets

    private init() {}

    // MARK: - Queries

    /// Load all open tickets grouped by project
    func refresh() {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }

        do {
            let all = try dbPool.read { db in
                try Ticket.fetchAll(db, sql: """
                    SELECT * FROM canvas_tickets
                    WHERE status NOT IN ('done', 'cancelled')
                    ORDER BY
                        CASE priority
                            WHEN 'critical' THEN 0
                            WHEN 'high' THEN 1
                            WHEN 'medium' THEN 2
                            WHEN 'low' THEN 3
                            ELSE 4
                        END,
                        CASE status
                            WHEN 'blocked' THEN 0
                            WHEN 'in_progress' THEN 1
                            WHEN 'review' THEN 2
                            WHEN 'pending' THEN 3
                            ELSE 4
                        END
                    """)
            }

            var grouped: [String: [Ticket]] = [:]
            for ticket in all {
                grouped[ticket.project, default: []].append(ticket)
            }
            tickets = grouped
        } catch {
            wtLog("[TicketStore] Failed to refresh: \(error)")
        }
    }

    /// Get tickets for a specific project
    func tickets(for project: String) -> [Ticket] {
        tickets[project] ?? []
    }

    /// Count open tickets for a project
    func openCount(for project: String) -> Int {
        tickets[project]?.count ?? 0
    }

    /// Count blocked tickets for a project
    func blockedCount(for project: String) -> Int {
        tickets[project]?.filter(\.isBlocked).count ?? 0
    }

    // MARK: - Scanning

    /// Scan all projects for TASK-*.md files and upsert into canvas_tickets
    func scanAll(developmentDir: String? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let devDir = developmentDir ?? "\(home)/Development"
        let fm = FileManager.default

        guard let dbPool = DatabaseManager.shared.dbPool else { return }
        guard let contents = try? fm.contentsOfDirectory(atPath: devDir) else { return }

        var allTickets: [Ticket] = []

        for dir in contents {
            let projectPath = "\(devDir)/\(dir)"
            let tasksDir = "\(projectPath)/.claude/epic/tasks"

            guard fm.fileExists(atPath: tasksDir) else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: tasksDir) else { continue }

            let taskFiles = files.filter { $0.hasPrefix("TASK-") && $0.hasSuffix(".md") }
            for file in taskFiles {
                if let ticket = parseTaskFile(path: "\(tasksDir)/\(file)", project: dir) {
                    allTickets.append(ticket)
                }
            }
        }

        // Upsert all tickets
        do {
            try dbPool.write { db in
                for ticket in allTickets {
                    try ticket.upsert(db)
                }
            }
            refresh()
            wtLog("[TicketStore] Scanned \(allTickets.count) tickets across projects")
        } catch {
            wtLog("[TicketStore] Failed to save tickets: \(error)")
        }
    }

    // MARK: - Mutations (writes back to TASK-*.md)

    /// Update ticket status in DB and write back to markdown file
    func updateStatus(ticket: Ticket, newStatus: String) {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }

        do {
            try dbPool.write { db in
                try db.execute(
                    sql: "UPDATE canvas_tickets SET status = ?, updated_at = datetime('now') WHERE id = ? AND project = ?",
                    arguments: [newStatus, ticket.id, ticket.project]
                )
            }

            // Write back to TASK-*.md file
            if let filePath = ticket.filePath {
                writeStatusToFile(filePath: filePath, newStatus: newStatus)
            }

            refresh()
        } catch {
            wtLog("[TicketStore] Failed to update ticket \(ticket.id): \(error)")
        }
    }

    // MARK: - Parsing

    private func parseTaskFile(path: String, project: String) -> Ticket? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

        let filename = (path as NSString).lastPathComponent
        guard let idMatch = filename.range(of: #"TASK-\d+"#, options: .regularExpression) else { return nil }
        let id = String(filename[idMatch])

        let title = extractField(content, pattern: #"^#\s+TASK-\d+:\s*(.+)"#) ?? id
        let status = extractField(content, pattern: #"\*\*Status:\*\*\s*(.+)"#)?.lowercased().replacingOccurrences(of: " ", with: "_") ?? "pending"
        let priority = extractField(content, pattern: #"\*\*Priority:\*\*\s*(.+)"#)?.lowercased() ?? "medium"
        let assignee = extractField(content, pattern: #"\*\*Assignee:\*\*\s*(.+)"#)
        let sprint = extractField(content, pattern: #"\*\*Sprint:\*\*\s*(.+)"#)
        let created = extractField(content, pattern: #"\*\*Created:\*\*\s*(.+)"#)
        let updated = extractField(content, pattern: #"\*\*Updated:\*\*\s*(.+)"#)

        // Extract description (between ## Description and next ##)
        let description = extractSection(content, header: "## Description")

        // Extract acceptance criteria as JSON array
        let criteria = extractCheckboxItems(content, header: "## Acceptance Criteria")
        let criteriaJSON = (try? String(data: JSONEncoder().encode(criteria), encoding: .utf8)) ?? "[]"

        // Extract blockers
        let blockerItems = extractCheckboxItems(content, header: "## Blockers")
        let blockersJSON = (try? String(data: JSONEncoder().encode(blockerItems), encoding: .utf8)) ?? "[]"

        return Ticket(
            id: id,
            project: project,
            title: title,
            description: description,
            status: status,
            priority: priority,
            assignee: assignee,
            sprint: sprint,
            filePath: path,
            acceptanceCriteria: criteriaJSON,
            blockers: blockersJSON,
            createdAt: created,
            updatedAt: updated,
            lastScanned: nil
        )
    }

    private func extractField(_ content: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, range: range) else { return nil }
        guard let captureRange = Range(match.range(at: 1), in: content) else { return nil }
        return String(content[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractSection(_ content: String, header: String) -> String? {
        guard let headerRange = content.range(of: header) else { return nil }
        let afterHeader = content[headerRange.upperBound...]
        // Find next ## header or end of string
        if let nextHeader = afterHeader.range(of: "\n## ") {
            let section = afterHeader[afterHeader.startIndex..<nextHeader.lowerBound]
            return String(section).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(afterHeader).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractCheckboxItems(_ content: String, header: String) -> [String] {
        guard let section = extractSection(content, header: header) else { return [] }
        let pattern = #"^-\s*\[[ x]\]\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive]) else { return [] }
        let range = NSRange(section.startIndex..., in: section)
        return regex.matches(in: section, range: range).compactMap { match in
            guard let captureRange = Range(match.range(at: 1), in: section) else { return nil }
            return String(section[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func writeStatusToFile(filePath: String, newStatus: String) {
        guard var content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }

        // Replace the status line
        let displayStatus = newStatus.replacingOccurrences(of: "_", with: " ").capitalized
        if let regex = try? NSRegularExpression(pattern: #"\*\*Status:\*\*\s*.+"#, options: .anchorsMatchLines) {
            let range = NSRange(content.startIndex..., in: content)
            content = regex.stringByReplacingMatches(in: content, range: range, withTemplate: "**Status:** \(displayStatus)")
        }

        // Update the Updated date
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        if let regex = try? NSRegularExpression(pattern: #"\*\*Updated:\*\*\s*.+"#, options: .anchorsMatchLines) {
            let range = NSRange(content.startIndex..., in: content)
            content = regex.stringByReplacingMatches(in: content, range: range, withTemplate: "**Updated:** \(today)")
        }

        try? content.write(toFile: filePath, atomically: true, encoding: .utf8)
    }
}
