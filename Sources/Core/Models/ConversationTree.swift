import Foundation
import GRDB

struct ConversationTree: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var project: String?
    var workingDirectory: String?
    var createdAt: Date
    var updatedAt: Date
    var archived: Bool

    /// Populated by TreeStore when loading
    var branches: [Branch] = []

    /// Root branch: the one with no parent
    var rootBranch: Branch? {
        branches.first { $0.parentBranchId == nil }
    }

    /// Active branch count
    var activeBranchCount: Int {
        branches.filter { $0.status == .active }.count
    }

    /// Total messages across all branches (set by query)
    var messageCount: Int = 0
}

// MARK: - GRDB Conformance

extension ConversationTree: FetchableRecord {
    init(row: Row) {
        id = row["id"]
        name = row["name"]
        project = row["project"]
        workingDirectory = row["working_directory"]
        createdAt = row["created_at"] as? Date ?? Date()
        updatedAt = row["updated_at"] as? Date ?? Date()
        archived = (row["archived"] as? Int ?? 0) != 0
    }
}

extension ConversationTree: PersistableRecord {
    static let databaseTableName = "canvas_trees"

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["name"] = name
        container["project"] = project
        container["working_directory"] = workingDirectory
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
        container["archived"] = archived ? 1 : 0
    }
}
