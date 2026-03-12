import Foundation
import Observation

/// Observable registry for live-streaming and completed job/dispatch output.
///
/// Running jobs and dispatches publish incremental output here via `appendOutput()`.
/// The Command Center subscribes to entries for live tailing. Completed output is
/// fetched on-demand from the database via `loadCompletedOutput()`.
///
/// Thread safety: `@MainActor` — all mutations on the main thread, matching the
/// SwiftUI observation pattern used by `GlobalStreamRegistry` and `HeartbeatStore`.
@MainActor
@Observable
final class JobOutputStreamStore {
    static let shared = JobOutputStreamStore()
    private init() {}

    // MARK: - Model

    struct OutputEntry: Identifiable {
        let id: String               // job or dispatch ID
        let kind: OutputKind
        let command: String           // command (job) or message (dispatch)
        let project: String?
        let startedAt: Date
        var output: String
        var isComplete: Bool
        var status: String            // "running", "completed", "failed", etc.
        var error: String?
    }

    enum OutputKind: String {
        case job
        case dispatch
    }

    // MARK: - State

    /// Active (streaming) entries — keyed by ID for O(1) lookup
    private(set) var activeEntries: [String: OutputEntry] = [:]

    /// Currently inspected entry ID (drives the inspector sheet)
    var inspectedId: String?

    /// The entry being inspected (live or loaded from DB)
    var inspectedEntry: OutputEntry?

    // MARK: - Live Streaming API

    /// Begin tracking a new streaming entry.
    func beginStream(id: String, kind: OutputKind, command: String, project: String?, status: String = "running") {
        activeEntries[id] = OutputEntry(
            id: id,
            kind: kind,
            command: command,
            project: project,
            startedAt: Date(),
            output: "",
            isComplete: false,
            status: status
        )
        // If this entry is currently being inspected, update the inspected copy
        if inspectedId == id {
            inspectedEntry = activeEntries[id]
        }
    }

    /// Append incremental output to a streaming entry.
    func appendOutput(id: String, chunk: String) {
        guard activeEntries[id] != nil else { return }
        activeEntries[id]?.output.append(chunk)
        if inspectedId == id {
            inspectedEntry = activeEntries[id]
        }
    }

    /// Mark a streaming entry as complete.
    func endStream(id: String, status: String, error: String? = nil) {
        guard activeEntries[id] != nil else { return }
        activeEntries[id]?.isComplete = true
        activeEntries[id]?.status = status
        activeEntries[id]?.error = error
        if inspectedId == id {
            inspectedEntry = activeEntries[id]
        }
        // Keep completed entries for 60s so the user can still tap to inspect
        let capturedId = id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.activeEntries.removeValue(forKey: capturedId)
        }
    }

    // MARK: - Inspection

    /// Open the inspector for a given ID. If the entry is active, use it directly.
    /// Otherwise, load from the database.
    func inspect(id: String, kind: OutputKind) {
        if let active = activeEntries[id] {
            inspectedEntry = active
            inspectedId = id
        } else {
            // Load from DB
            inspectedEntry = loadFromDB(id: id, kind: kind)
            inspectedId = id
        }
    }

    func dismissInspector() {
        inspectedId = nil
        inspectedEntry = nil
    }

    // MARK: - DB Loading

    private func loadFromDB(id: String, kind: OutputKind) -> OutputEntry? {
        guard let pool = DatabaseManager.shared.dbPool else { return nil }

        switch kind {
        case .job:
            guard let job = try? pool.read({ db in
                try WorldTreeJob.fetchOne(db, key: id)
            }) else { return nil }
            return OutputEntry(
                id: job.id,
                kind: .job,
                command: job.command,
                project: nil,
                startedAt: job.createdAt,
                output: job.output ?? "",
                isComplete: !job.isActive,
                status: job.status.rawValue,
                error: job.error
            )

        case .dispatch:
            guard let dispatch = try? pool.read({ db in
                try WorldTreeDispatch.fetchOne(db, key: id)
            }) else { return nil }
            return OutputEntry(
                id: dispatch.id,
                kind: .dispatch,
                command: dispatch.message,
                project: dispatch.project,
                startedAt: dispatch.startedAt ?? dispatch.createdAt,
                output: dispatch.resultText ?? "",
                isComplete: !dispatch.isActive,
                status: dispatch.status.rawValue,
                error: dispatch.error
            )
        }
    }
}
