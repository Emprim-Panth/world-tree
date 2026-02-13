import Foundation
import GRDB

/// A background job tracked by Canvas
struct CanvasJob: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "canvas_jobs"

    var id: String
    let type: String          // "background_run", "build", "test"
    let command: String
    let workingDirectory: String
    var branchId: String?
    var status: JobStatus
    var output: String?
    var error: String?
    let createdAt: Date
    var completedAt: Date?

    enum JobStatus: String, Codable, DatabaseValueConvertible {
        case queued
        case running
        case completed
        case failed
        case cancelled
    }

    init(
        id: String = UUID().uuidString,
        type: String = "background_run",
        command: String,
        workingDirectory: String,
        branchId: String? = nil,
        status: JobStatus = .queued,
        output: String? = nil,
        error: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.command = command
        self.workingDirectory = workingDirectory
        self.branchId = branchId
        self.status = status
        self.output = output
        self.error = error
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, type, command
        case workingDirectory = "working_directory"
        case branchId = "branch_id"
        case status, output, error
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }

    /// Compact display string
    var displayCommand: String {
        command.count > 60 ? String(command.prefix(60)) + "..." : command
    }

    var isActive: Bool {
        status == .queued || status == .running
    }
}
