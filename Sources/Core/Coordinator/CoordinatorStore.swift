import Foundation
import GRDB

// MARK: - Models

/// A high-level goal being orchestrated by the coordinator.
struct CoordinatorPlan: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "coordinator_plans"

    let id: String
    let project: String
    let workingDirectory: String
    let goal: String
    var status: PlanStatus
    let ollamaModel: String
    var taskCount: Int
    var completedTaskCount: Int
    var stateSummary: String?
    var error: String?
    let createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    enum PlanStatus: String, Codable, DatabaseValueConvertible, Sendable {
        case planning, running, paused, completed, failed, cancelled
    }

    var progressFraction: Double {
        guard taskCount > 0 else { return 0 }
        return Double(completedTaskCount) / Double(taskCount)
    }

    var isActive: Bool {
        status == .planning || status == .running || status == .paused
    }

    enum CodingKeys: String, CodingKey {
        case id, project, goal, status, error
        case workingDirectory = "working_directory"
        case ollamaModel = "ollama_model"
        case taskCount = "task_count"
        case completedTaskCount = "completed_task_count"
        case stateSummary = "state_summary"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
    }

    init(
        id: String = UUID().uuidString,
        project: String,
        workingDirectory: String,
        goal: String,
        status: PlanStatus = .planning,
        ollamaModel: String = "llama3.2",
        taskCount: Int = 0,
        completedTaskCount: Int = 0,
        stateSummary: String? = nil,
        error: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.project = project
        self.workingDirectory = workingDirectory
        self.goal = goal
        self.status = status
        self.ollamaModel = ollamaModel
        self.taskCount = taskCount
        self.completedTaskCount = completedTaskCount
        self.stateSummary = stateSummary
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

/// A single task within a coordinator plan.
struct CoordinatorTask: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "coordinator_tasks"

    let id: String
    let planId: String
    let sequence: Int
    let title: String
    let description: String
    var status: TaskStatus
    var dispatchId: String?
    var dependsOn: String     // JSON array of task IDs
    var resultSummary: String?
    var error: String?
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?

    enum TaskStatus: String, Codable, DatabaseValueConvertible, Sendable {
        case queued, dispatched, running, completed, failed, skipped
    }

    var isTerminal: Bool {
        status == .completed || status == .failed || status == .skipped
    }

    var statusIcon: String {
        switch status {
        case .queued: return "clock"
        case .dispatched, .running: return "arrow.trianglehead.2.clockwise"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, sequence, title, description, status, error
        case planId = "plan_id"
        case dispatchId = "dispatch_id"
        case dependsOn = "depends_on"
        case resultSummary = "result_summary"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    init(
        id: String = UUID().uuidString,
        planId: String,
        sequence: Int,
        title: String,
        description: String,
        status: TaskStatus = .queued,
        dispatchId: String? = nil,
        dependsOn: [String] = [],
        resultSummary: String? = nil,
        error: String? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.planId = planId
        self.sequence = sequence
        self.title = title
        self.description = description
        self.status = status
        self.dispatchId = dispatchId
        self.dependsOn = (try? String(data: JSONEncoder().encode(dependsOn), encoding: .utf8)) ?? "[]"
        self.resultSummary = resultSummary
        self.error = error
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

// MARK: - Store

/// GRDB read/write layer for coordinator plans and tasks.
@MainActor
enum CoordinatorStore {

    // MARK: - Plans

    static func insertPlan(_ plan: CoordinatorPlan) throws {
        try DatabaseManager.shared.write { db in
            try plan.insert(db)
        }
    }

    static func updatePlanStatus(_ id: String, status: CoordinatorPlan.PlanStatus, error: String? = nil) throws {
        try DatabaseManager.shared.write { db in
            try db.execute(
                sql: """
                    UPDATE coordinator_plans
                    SET status = ?, error = ?, updated_at = datetime('now'),
                        completed_at = CASE WHEN ? IN ('completed','failed','cancelled') THEN datetime('now') ELSE completed_at END
                    WHERE id = ?
                    """,
                arguments: [status.rawValue, error, status.rawValue, id]
            )
        }
    }

    static func updatePlanProgress(_ id: String, taskCount: Int, completedTaskCount: Int, stateSummary: String? = nil) throws {
        try DatabaseManager.shared.write { db in
            try db.execute(
                sql: """
                    UPDATE coordinator_plans
                    SET task_count = ?, completed_task_count = ?, state_summary = ?, updated_at = datetime('now')
                    WHERE id = ?
                    """,
                arguments: [taskCount, completedTaskCount, stateSummary, id]
            )
        }
    }

    static func fetchActivePlans() throws -> [CoordinatorPlan] {
        try DatabaseManager.shared.read { db in
            guard try db.tableExists("coordinator_plans") else { return [] }
            return try CoordinatorPlan
                .filter(["planning", "running", "paused"].contains(Column("status")))
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    static func fetchAllPlans(limit: Int = 20) throws -> [CoordinatorPlan] {
        try DatabaseManager.shared.read { db in
            guard try db.tableExists("coordinator_plans") else { return [] }
            return try CoordinatorPlan
                .order(Column("created_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Tasks

    static func insertTasks(_ tasks: [CoordinatorTask]) throws {
        try DatabaseManager.shared.write { db in
            for task in tasks {
                try task.insert(db)
            }
        }
    }

    static func updateTaskStatus(
        _ id: String,
        status: CoordinatorTask.TaskStatus,
        dispatchId: String? = nil,
        resultSummary: String? = nil,
        error: String? = nil
    ) throws {
        try DatabaseManager.shared.write { db in
            try db.execute(
                sql: """
                    UPDATE coordinator_tasks
                    SET status = ?,
                        dispatch_id = COALESCE(?, dispatch_id),
                        result_summary = COALESCE(?, result_summary),
                        error = COALESCE(?, error),
                        started_at = CASE WHEN ? = 'dispatched' AND started_at IS NULL THEN datetime('now') ELSE started_at END,
                        completed_at = CASE WHEN ? IN ('completed','failed','skipped') THEN datetime('now') ELSE completed_at END
                    WHERE id = ?
                    """,
                arguments: [status.rawValue, dispatchId, resultSummary, error, status.rawValue, status.rawValue, id]
            )
        }
    }

    static func fetchTasks(forPlan planId: String) throws -> [CoordinatorTask] {
        try DatabaseManager.shared.read { db in
            guard try db.tableExists("coordinator_tasks") else { return [] }
            return try CoordinatorTask
                .filter(Column("plan_id") == planId)
                .order(Column("sequence").asc)
                .fetchAll(db)
        }
    }

    static func fetchTask(byDispatchId dispatchId: String) throws -> CoordinatorTask? {
        try DatabaseManager.shared.read { db in
            guard try db.tableExists("coordinator_tasks") else { return nil }
            return try CoordinatorTask
                .filter(Column("dispatch_id") == dispatchId)
                .fetchOne(db)
        }
    }
}
