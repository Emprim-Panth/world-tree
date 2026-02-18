import Foundation
import GRDB

/// Manages background job execution and tracking.
/// Jobs run as child processes with output captured to the database.
/// Uses dbPool directly to avoid @MainActor isolation issues.
actor JobQueue {
    static let shared = JobQueue()

    private var runningProcesses: [String: Process] = [:]
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let maxOutputSize = 200_000 // 200KB per job

    /// Get dbPool directly (thread-safe, no actor isolation needed)
    private var dbPool: DatabasePool? {
        // Access the stored pool via MainActor hop
        // This is safe because dbPool is set once during setup and never changes
        return _dbPool
    }
    private static var _sharedDbPool: DatabasePool?
    private var _dbPool: DatabasePool? { Self._sharedDbPool }

    /// Call from main actor after DatabaseManager.setup()
    @MainActor
    static func configure() {
        _sharedDbPool = DatabaseManager.shared.dbPool
    }

    // MARK: - DB Helpers

    private func dbWrite(_ block: (Database) throws -> Void) {
        do {
            try dbPool?.write(block)
        } catch {
            canvasLog("[JobQueue] DB write failed: \(error)")
        }
    }

    private func dbRead<T>(_ block: (Database) throws -> T) -> T? {
        try? dbPool?.read(block)
    }

    // MARK: - Enqueue

    /// Enqueue a command for background execution. Returns the job ID immediately.
    func enqueue(
        command: String,
        workingDirectory: String,
        branchId: String? = nil,
        type: String = "background_run"
    ) async -> String {
        let job = CanvasJob(
            type: type,
            command: command,
            workingDirectory: workingDirectory,
            branchId: branchId
        )

        dbWrite { db in try job.insert(db) }

        Task { [job] in
            await self.execute(job)
        }

        return job.id
    }

    // MARK: - Execute

    private func execute(_ job: CanvasJob) async {
        var mutableJob = job
        mutableJob.status = .running
        dbWrite { db in try mutableJob.update(db) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", job.command]
        proc.currentDirectoryURL = URL(fileURLWithPath: job.workingDirectory)

        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(home)/.local/bin:\(home)/.cortana/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        env["HOME"] = home
        proc.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        runningProcesses[job.id] = proc

        do {
            try proc.run()
        } catch {
            mutableJob.status = .failed
            mutableJob.error = "Failed to launch: \(error.localizedDescription)"
            mutableJob.completedAt = Date()
            dbWrite { db in try mutableJob.update(db) }
            runningProcesses.removeValue(forKey: job.id)
            await NotificationManager.shared.notifyJobComplete(mutableJob)
            return
        }

        proc.waitUntilExit()
        runningProcesses.removeValue(forKey: job.id)

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        var output = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        if !stderr.isEmpty {
            output += "\n[stderr]\n\(stderr)"
        }

        if output.count > maxOutputSize {
            output = String(output.prefix(maxOutputSize)) + "\n[Output truncated at \(maxOutputSize) bytes]"
        }

        let exitCode = proc.terminationStatus
        mutableJob.output = output
        mutableJob.status = exitCode == 0 ? .completed : .failed
        mutableJob.completedAt = Date()

        if exitCode != 0 {
            mutableJob.error = "Exit code: \(exitCode)"
        }

        dbWrite { db in try mutableJob.update(db) }

        await NotificationManager.shared.notifyJobComplete(mutableJob)
    }

    // MARK: - Cancel

    func cancel(_ jobId: String) {
        if let proc = runningProcesses[jobId], proc.isRunning {
            proc.terminate()
            runningProcesses.removeValue(forKey: jobId)
        }

        dbWrite { db in
            try db.execute(
                sql: "UPDATE canvas_jobs SET status = 'cancelled', completed_at = datetime('now') WHERE id = ?",
                arguments: [jobId]
            )
        }
    }

    // MARK: - Query

    nonisolated func getJob(_ id: String) -> CanvasJob? {
        Self._sharedDbPool.flatMap { pool in
            try? pool.read { db in
                try CanvasJob.fetchOne(db, key: id)
            }
        }
    }

    nonisolated func activeJobs() -> [CanvasJob] {
        guard let pool = Self._sharedDbPool else { return [] }
        return (try? pool.read { db in
            try CanvasJob
                .filter(Column("status") == "queued" || Column("status") == "running")
                .order(Column("created_at").desc)
                .fetchAll(db)
        }) ?? []
    }

    nonisolated func recentJobs(limit: Int = 20) -> [CanvasJob] {
        guard let pool = Self._sharedDbPool else { return [] }
        return (try? pool.read { db in
            try CanvasJob
                .order(Column("created_at").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }
}
