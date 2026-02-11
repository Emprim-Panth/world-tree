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

struct Branch: Identifiable, Equatable, Hashable {
    let id: String
    let treeId: String
    var sessionId: String?
    var parentBranchId: String?
    var forkFromMessageId: Int?
    var branchType: BranchType
    var title: String?
    var status: BranchStatus
    var summary: String?
    var model: String?
    var daemonTaskId: String?
    var contextSnapshot: String?
    var collapsed: Bool
    var createdAt: Date
    var updatedAt: Date

    /// Populated by TreeStore when loading the tree
    var children: [Branch] = []

    /// Display title: uses explicit title, or generates from type + creation
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "\(branchType.rawValue.capitalized) — \(formatter.string(from: createdAt))"
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
        container["collapsed"] = collapsed ? 1 : 0
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
    }
}
