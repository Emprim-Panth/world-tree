import Foundation
import GRDB

// MARK: - Project Activity

/// Aggregated activity for a single project — dispatches, jobs, and tmux sessions.
struct ProjectActivity: Identifiable {
    var id: String { project.path }
    let project: CachedProject
    var activeDispatches: [WorldTreeDispatch]
    var activeJobs: [WorldTreeJob]
    var activeTmuxSessions: [TmuxSession]

    var isActive: Bool {
        !activeDispatches.isEmpty || !activeJobs.isEmpty || activeTmuxSessions.contains(where: \.isClaudeSession)
    }

    var totalActiveTasks: Int {
        activeDispatches.count + activeJobs.count + activeTmuxSessions.filter(\.isClaudeSession).count
    }

    var lastActivityDate: Date? {
        let dates: [Date?] = [
            activeDispatches.compactMap(\.startedAt).max(),
            activeJobs.map(\.createdAt).max(),
            activeTmuxSessions.map(\.lastActivity).max()
        ]
        return dates.compactMap { $0 }.max()
    }
}

// MARK: - Command Center ViewModel

/// Drives the Command Center with reactive GRDB observations.
/// Groups all concurrent work by project for the bird's eye view.
@MainActor
@Observable
final class CommandCenterViewModel {
    var projects: [CachedProject] = []
    var activeDispatches: [WorldTreeDispatch] = []
    var recentDispatches: [WorldTreeDispatch] = []
    var activeJobs: [WorldTreeJob] = []
    var projectActivities: [ProjectActivity] = []
    var isShowingDispatchSheet = false

    // Compass + Ticket state
    var compassStates: [String: CompassState] = [:]
    var ticketCounts: [String: Int] = [:]   // project → open ticket count
    var blockedCounts: [String: Int] = [:]  // project → blocked ticket count

    private var observationTask: Task<Void, Never>?
    /// Fingerprint of the last rebuild — skip if dispatches + jobs haven't changed.
    private var lastRebuildFingerprint: String = ""

    // MARK: - Lifecycle

    func startObserving() {
        guard observationTask == nil else { return }

        // Load projects + Compass/Ticket state
        loadProjects()
        refreshCompassAndTickets()

        // Build initial project activities immediately — don't wait for dispatch observation
        rebuildProjectActivities()

        // Start reactive observation of dispatches + jobs
        observationTask = Task { [weak self] in
            guard let dbPool = DatabaseManager.shared.dbPool else { return }

            let observation = ValueObservation.trackingConstantRegion { db -> ([WorldTreeDispatch], [WorldTreeDispatch], [WorldTreeJob]) in
                let active = try WorldTreeDispatch
                    .filter(Column("status") == "queued" || Column("status") == "running")
                    .order(Column("created_at").desc)
                    .fetchAll(db)

                let recent = try WorldTreeDispatch
                    .filter(Column("status") == "completed" || Column("status") == "failed")
                    .order(Column("completed_at").desc)
                    .limit(20)
                    .fetchAll(db)

                let jobs = try WorldTreeJob
                    .filter(Column("status") == "queued" || Column("status") == "running")
                    .order(Column("created_at").desc)
                    .fetchAll(db)

                return (active, recent, jobs)
            }

            do {
                for try await (active, recent, jobs) in observation.values(in: dbPool) {
                    self?.activeDispatches = active
                    self?.recentDispatches = recent
                    self?.activeJobs = jobs
                    self?.rebuildProjectActivities()
                }
            } catch {
                // Observation cancelled
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Project Loading

    func loadProjects() {
        do {
            projects = try ProjectCache().getAll()
        } catch {
            wtLog("[CommandCenter] Failed to load projects: \(error)")
        }
    }

    // MARK: - Dispatch Actions

    func dispatch(message: String, project: CachedProject, model: String?) {
        let stream = ClaudeBridge.shared.dispatch(
            message: message,
            project: project.name,
            workingDirectory: project.path,
            model: model,
            origin: .ui
        )

        // Consume the stream — results are tracked in DB via AgentSDKProvider
        Task {
            for await _ in stream {}
        }
    }

    func cancelDispatch(_ id: String) {
        ClaudeBridge.shared.cancelDispatch(id)
    }

    // MARK: - Activity Grouping

    private func rebuildProjectActivities() {
        // Skip rebuild when the underlying data hasn't changed (but always allow first build).
        let fingerprint = activeDispatches.map(\.id).joined() + activeJobs.map(\.id).joined()
        let isFirstBuild = projectActivities.isEmpty && !projects.isEmpty
        guard isFirstBuild || fingerprint != lastRebuildFingerprint else { return }
        lastRebuildFingerprint = fingerprint

        let tmuxSessions = DaemonService.shared.tmuxSessions

        var activities: [String: ProjectActivity] = [:]

        // Initialize from projects
        for project in projects {
            activities[project.name.lowercased()] = ProjectActivity(
                project: project,
                activeDispatches: [],
                activeJobs: [],
                activeTmuxSessions: []
            )
        }

        // Group dispatches by project
        for dispatch in activeDispatches {
            let key = dispatch.project.lowercased()
            if activities[key] != nil {
                activities[key]?.activeDispatches.append(dispatch)
            }
        }

        // Group jobs — try to match by working directory to project path
        for job in activeJobs {
            let matched = projects.first { job.workingDirectory.hasPrefix($0.path) }
            if let matched {
                let key = matched.name.lowercased()
                activities[key]?.activeJobs.append(job)
            }
        }

        // Group tmux sessions by project name
        for session in tmuxSessions {
            if let projectName = session.projectName {
                let key = projectName.lowercased()
                if activities[key] != nil {
                    activities[key]?.activeTmuxSessions.append(session)
                }
            }
        }

        // Sort: active projects first, then by attention score, then by last activity
        projectActivities = activities.values.sorted(by: { a, b in
            if a.isActive != b.isActive { return a.isActive }

            // Use Compass attention score when available
            let aScore = compassStates[a.project.name]?.attentionScore ?? 0
            let bScore = compassStates[b.project.name]?.attentionScore ?? 0
            if aScore != bScore { return aScore > bScore }

            let aDate = a.lastActivityDate ?? .distantPast
            let bDate = b.lastActivityDate ?? .distantPast
            return aDate > bDate
        })
    }

    // MARK: - Compass & Tickets

    func refreshCompassAndTickets() {
        let compassStore = CompassStore.shared
        compassStore.refresh()
        compassStates = compassStore.states

        let ticketStore = TicketStore.shared
        ticketStore.scanAll()
        for project in projects {
            ticketCounts[project.name] = ticketStore.openCount(for: project.name)
            blockedCounts[project.name] = ticketStore.blockedCount(for: project.name)
        }
    }
}
