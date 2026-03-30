import Foundation
import GRDB
import Observation

// MARK: - Ticket Model

struct Ticket: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
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
@Observable
final class TicketStore {
    static let shared = TicketStore()

    private(set) var tickets: [String: [Ticket]] = [:] // project → tickets
    /// Last time `scanAll()` completed successfully. Nil = never scanned this session.
    private(set) var lastScanDate: Date?
    /// True when a scan is currently running.
    private(set) var isScanning = false

    /// DispatchSource file-descriptor watchers keyed by tasks-directory path.
    private var dirWatchers: [String: DispatchSourceFileSystemObject] = [:]

    private init() {}

    // MARK: - File-system watching

    /// Watch all `.claude/epic/tasks` directories under `developmentDir` for changes.
    /// When any watched directory is written to, trigger a targeted rescan after a
    /// short debounce so rapid batch writes only generate one scan.
    func startWatching(developmentDir: String? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let devDir = developmentDir ?? "\(home)/Development"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: devDir) else { return }

        for dir in contents {
            let tasksDir = "\(devDir)/\(dir)/.claude/epic/tasks"
            guard FileManager.default.fileExists(atPath: tasksDir) else { continue }
            guard dirWatchers[tasksDir] == nil else { continue }

            let fd = open(tasksDir, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    // Debounce — batch file writes arrive in rapid succession
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.scanProject(projectDir: "\(devDir)/\(dir)", project: dir)
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            dirWatchers[tasksDir] = source
        }
    }

    /// Stop all file-system watchers (call on app background / deinit).
    func stopWatching() {
        for (_, source) in dirWatchers { source.cancel() }
        dirWatchers.removeAll()
    }

    // MARK: - Targeted project scan

    /// Rescan a single project's tasks directory and update DB + published state.
    func scanProject(projectDir: String, project: String) {
        let tasksDir = "\(projectDir)/.claude/epic/tasks"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: tasksDir) else { return }
        guard let dbPool = DatabaseManager.shared.dbPool else { return }

        let taskFiles = files.filter { $0.hasPrefix("TASK-") && $0.hasSuffix(".md") }
        let tickets = taskFiles.compactMap { parseTaskFile(path: "\(tasksDir)/\($0)", project: project) }

        do {
            try dbPool.write { db in
                for ticket in tickets { try ticket.upsert(db) }
            }
            refresh()
            wtLog("[TicketStore] Rescanned \(project): \(tickets.count) tickets")
        } catch {
            wtLog("[TicketStore] Project rescan failed for \(project): \(error)")
        }
    }

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

    /// All project names that have open tickets, sorted alphabetically
    var allProjectNames: [String] {
        Array(tickets.keys).sorted()
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

    /// Fetch completed (done + cancelled) tickets for a project directly from DB
    func completedTickets(for project: String) -> [Ticket] {
        guard let dbPool = DatabaseManager.shared.dbPool else { return [] }
        do {
            return try dbPool.read { db in
                try Ticket.fetchAll(db, sql: """
                    SELECT * FROM canvas_tickets
                    WHERE project = ? AND status IN ('done', 'cancelled')
                    ORDER BY updated_at DESC
                    """, arguments: [project])
            }
        } catch {
            wtLog("[TicketStore] Failed to fetch completed tickets for \(project): \(error)")
            return []
        }
    }

    /// Fetch all completed tickets across all projects, grouped by project
    func allCompletedTickets() -> [String: [Ticket]] {
        guard let dbPool = DatabaseManager.shared.dbPool else { return [:] }
        do {
            let all = try dbPool.read { db in
                try Ticket.fetchAll(db, sql: """
                    SELECT * FROM canvas_tickets
                    WHERE status IN ('done', 'cancelled')
                    ORDER BY updated_at DESC
                    """)
            }
            var grouped: [String: [Ticket]] = [:]
            for ticket in all {
                grouped[ticket.project, default: []].append(ticket)
            }
            return grouped
        } catch {
            wtLog("[TicketStore] Failed to fetch all completed tickets: \(error)")
            return [:]
        }
    }

    // MARK: - Scanning

    /// Scan all projects for TASK-*.md files and upsert into canvas_tickets.
    /// Also starts file-system watching so future external edits are picked up automatically.
    func scanAll(developmentDir: String? = nil) {
        isScanning = true
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let devDir = developmentDir ?? "\(home)/Development"
        let fm = FileManager.default

        guard let dbPool = DatabaseManager.shared.dbPool else { isScanning = false; return }
        guard let contents = try? fm.contentsOfDirectory(atPath: devDir) else { isScanning = false; return }

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
            lastScanDate = Date()
            wtLog("[TicketStore] Scanned \(allTickets.count) tickets across projects")
        } catch {
            wtLog("[TicketStore] Failed to save tickets: \(error)")
        }

        isScanning = false
        // Start watching for external file changes now that directories are known
        startWatching(developmentDir: devDir)
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
        let status = extractField(content, pattern: #"\*\*Status(?::\*\*|\*\*:)\s*(.+)"#)?.lowercased().replacingOccurrences(of: " ", with: "_") ?? "pending"
        let priority = extractField(content, pattern: #"\*\*Priority(?::\*\*|\*\*:)\s*(.+)"#)?.lowercased() ?? "medium"
        let assignee = extractField(content, pattern: #"\*\*Assignee(?::\*\*|\*\*:)\s*(.+)"#)
        let sprint = extractField(content, pattern: #"\*\*Sprint(?::\*\*|\*\*:)\s*(.+)"#)
        let created = extractField(content, pattern: #"\*\*Created(?::\*\*|\*\*:)\s*(.+)"#)
        let updated = extractField(content, pattern: #"\*\*Updated(?::\*\*|\*\*:)\s*(.+)"#)

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
        if let regex = try? NSRegularExpression(pattern: #"\*\*Status(?::\*\*|\*\*:)\s*.+"#, options: .anchorsMatchLines) {
            let range = NSRange(content.startIndex..., in: content)
            content = regex.stringByReplacingMatches(in: content, range: range, withTemplate: "**Status:** \(displayStatus)")
        }

        // Update the Updated date
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        if let regex = try? NSRegularExpression(pattern: #"\*\*Updated(?::\*\*|\*\*:)\s*.+"#, options: .anchorsMatchLines) {
            let range = NSRange(content.startIndex..., in: content)
            content = regex.stringByReplacingMatches(in: content, range: range, withTemplate: "**Updated:** \(today)")
        }

        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch {
            wtLog("[TicketStore] Failed to write status to \(filePath): \(error)")
        }
    }
}
