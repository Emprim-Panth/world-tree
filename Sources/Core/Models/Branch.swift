import Foundation
import GRDB

enum BranchType: String, Codable, CaseIterable, DatabaseValueConvertible {
    case conversation
    case implementation
    case exploration
}

enum BranchStatus: String, Codable, CaseIterable, DatabaseValueConvertible {
    case active
    case completed
    case archived
    case failed
}

/// Controls how context compaction behaves for a branch.
enum CompactionMode: String, Codable, CaseIterable, DatabaseValueConvertible {
    /// Automatic rotation when context pressure exceeds threshold (default)
    case auto
    /// Show warning at threshold but don't rotate until user confirms
    case manual
    /// Never rotate — context grows until provider limit
    case frozen
}

struct Branch: Identifiable, Equatable, Hashable {
    let id: String
    let treeId: String
    var sessionId: String?
    var parentBranchId: String?
    var forkFromMessageId: String?
    var branchType: BranchType
    var title: String?
    var status: BranchStatus
    var summary: String?
    var model: String?
    var daemonTaskId: String?
    var contextSnapshot: String?
    var tmuxSessionName: String?
    var compactionMode: CompactionMode
    var collapsed: Bool
    var createdAt: Date
    var updatedAt: Date

    /// Populated by TreeStore when loading the tree
    var children: [Branch] = []
    var depth: Int = 0
    var messageCount: Int = 0

    private static let displayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// Display title: uses explicit title, or generates from type + creation
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "\(branchType.rawValue.capitalized) — \(Branch.displayTitleFormatter.string(from: createdAt))"
    }
}

// MARK: - GRDB Conformance

extension Branch: FetchableRecord {
    init(row: Row) {
        id = row["id"]
        treeId = row["tree_id"]
        sessionId = row["session_id"]
        parentBranchId = row["parent_branch_id"]
        forkFromMessageId = row["fork_from_message_id"]
        branchType = BranchType(rawValue: row["branch_type"] as String) ?? .conversation
        title = row["title"]
        status = BranchStatus(rawValue: row["status"] as String) ?? .active
        summary = row["summary"]
        model = row["model"]
        daemonTaskId = row["daemon_task_id"]
        contextSnapshot = row["context_snapshot"]
        tmuxSessionName = row["tmux_session_name"]
        compactionMode = CompactionMode(rawValue: row["compaction_mode"] as? String ?? "auto") ?? .auto
        collapsed = (row["collapsed"] as? Int ?? 0) != 0
        createdAt = row["created_at"] as? Date ?? Date()
        updatedAt = row["updated_at"] as? Date ?? Date()
    }
}

extension Branch: PersistableRecord {
    static let databaseTableName = "canvas_branches"

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["tree_id"] = treeId
        container["session_id"] = sessionId
        container["parent_branch_id"] = parentBranchId
        container["fork_from_message_id"] = forkFromMessageId
        container["branch_type"] = branchType
        container["title"] = title
        container["status"] = status
        container["summary"] = summary
        container["model"] = model
        container["daemon_task_id"] = daemonTaskId
        container["context_snapshot"] = contextSnapshot
        container["tmux_session_name"] = tmuxSessionName
        container["compaction_mode"] = compactionMode
        container["collapsed"] = collapsed ? 1 : 0
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
    }
}
