import Foundation

/// High-level daemon operations — dispatch, status, session management.
/// Wraps DaemonSocket with published state for SwiftUI binding.
@MainActor
final class DaemonService: ObservableObject {
    static let shared = DaemonService()

    @Published var isConnected: Bool = false
    @Published var activeSessions: [DaemonSession] = []
    @Published var tmuxSessions: [TmuxSession] = []
    @Published var lastError: String?

    /// Whether to automatically manage context for tmux Claude sessions.
    @Published var autoManageTmuxContext: Bool = true

    private let socket = DaemonSocket()
    private var healthTimer: Timer?
    /// Tasks spawned by the health timer — cancelled on stopMonitoring().
    /// Only accessed from @MainActor (append + cancel + removeAll all happen on MainActor).
    private var pendingTasks: [Task<Void, Never>] = []

    /// Counter for health ticks — tmux discovery only runs every 3rd tick (30s).
    private var healthTickCount = 0

    /// Track sessions we've already sent a /compact to, so we don't spam.
    /// Key: session name, Value: timestamp of last intervention.
    /// Pruned periodically to prevent unbounded growth.
    private var tmuxRotationHistory: [String: Date] = [:]

    /// Minimum interval between auto-rotations for the same session (5 minutes).
    private let rotationCooldown: TimeInterval = 300

    /// Maximum entries before pruning old rotation history
    private let maxRotationHistorySize = 50

    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoBasic = ISO8601DateFormatter()

    private init() {}

    // MARK: - Lifecycle

    func startMonitoring() {
        guard healthTimer == nil else { return } // Already monitoring
        checkHealth()
        Task {
            await refreshSessions()
            refreshTmuxSessions()
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Create and track the task in the same @MainActor block to
                // serialize access to pendingTasks — avoids the race where a
                // separate @MainActor hop could interleave with another timer fire.
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.checkHealth()
                    await self.refreshSessions()
                    self.healthTickCount += 1
                    if self.healthTickCount % 3 == 0 {
                        self.refreshTmuxSessions()
                    }
                }
                self.pendingTasks.append(task)
                // Prune completed tasks to prevent unbounded growth
                self.pendingTasks.removeAll { $0.isCancelled }
            }
        }
    }

    func stopMonitoring() {
        healthTimer?.invalidate()
        healthTimer = nil
        pendingTasks.forEach { $0.cancel() }
        pendingTasks.removeAll()
    }

    // MARK: - Health

    func checkHealth() {
        // Primary: HTTP health endpoint (Cortana daemon on port 8765).
        // Async — fires a background task; result lands on MainActor via @MainActor class.
        Task {
            await checkHTTPHealth()
        }
    }

    private func checkHTTPHealth() async {
        // 1. Try HTTP health endpoint first (Swift daemon — port 8765, no socket required).
        if let url = URL(string: "\(AppConstants.daemonAPIURL)/health") {
            do {
                var req = URLRequest(url: url, timeoutInterval: 3)
                req.httpMethod = "GET"
                let (_, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    isConnected = true
                    return
                }
            } catch {
                wtLog("[DaemonService] HTTP health check failed: \(error.localizedDescription)")
            }
        }

        // 2. Fallback: health file (written by TS daemon or older Swift daemon builds).
        let healthPath = AppConstants.daemonHealthPath
        if let data = FileManager.default.contents(atPath: healthPath),
           let health = try? JSONDecoder().decode(DaemonHealthFile.self, from: data) {
            let age = Date().timeIntervalSince1970 - health.timestamp
            isConnected = age < 60
            return
        }

        // 3. Last resort: Unix socket file presence.
        isConnected = FileManager.default.fileExists(atPath: AppConstants.daemonSocketPath)
    }

    // MARK: - Dispatch

    /// Dispatch a task to the daemon for execution.
    /// Returns the task ID on success.
    func dispatch(
        message: String,
        project: String,
        priority: String = "normal",
        sessionId: String? = nil
    ) async -> String? {
        do {
            let command = DaemonCommand.dispatch(
                message: message,
                project: project,
                priority: priority,
                sessionId: sessionId
            )
            let response = try await socket.send(command)
            lastError = response.error
            if let err = response.error {
                wtLog("[DaemonService] dispatch error: \(err)")
            }
            return response.taskId
        } catch {
            lastError = error.localizedDescription
            wtLog("[DaemonService] dispatch failed: \(error)")
            return nil
        }
    }

    // MARK: - Sessions

    func refreshSessions() async {
        do {
            let response = try await socket.send(.sessions)
            lastError = response.error
            if let err = response.error {
                wtLog("[DaemonService] sessions error: \(err)")
            }

            // Parse sessions from response.data (array of dictionaries)
            guard let anyCodable = response.data,
                  let rawArray = anyCodable.value as? [AnyCodable] else {
                activeSessions = []
                return
            }

            activeSessions = rawArray.compactMap { parseDaemonSession(from: $0) }
        } catch {
            lastError = error.localizedDescription
            wtLog("[DaemonService] refreshSessions failed: \(error)")
        }
    }

    /// Parse a single DaemonSession from an AnyCodable dictionary.
    /// Daemon sends snake_case keys: task_id, project, model, started_at, status.
    private func parseDaemonSession(from anyCodable: AnyCodable) -> DaemonSession? {
        guard let dict = anyCodable.value as? [String: AnyCodable] else { return nil }

        guard let taskId = dict["task_id"]?.value as? String,
              let project = dict["project"]?.value as? String,
              let status = dict["status"]?.value as? String else {
            return nil
        }

        let model = dict["model"]?.value as? String

        var startedAt: Date?
        if let timestamp = dict["started_at"]?.value as? Double {
            startedAt = Date(timeIntervalSince1970: timestamp)
        } else if let timestamp = dict["started_at"]?.value as? Int {
            startedAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
        } else if let isoString = dict["started_at"]?.value as? String {
            startedAt = Self.isoWithFractional.date(from: isoString)
                ?? Self.isoBasic.date(from: isoString)
        }

        return DaemonSession(
            taskId: taskId,
            project: project,
            model: model,
            startedAt: startedAt,
            status: status
        )
    }

    // MARK: - Tmux Sessions

    /// Discover active tmux sessions with pane-level data and Claude context info.
    /// Automatically manages context for high-pressure Claude sessions.
    func refreshTmuxSessions() {
        let shouldAutoManage = autoManageTmuxContext
        Task.detached { [weak self] in
            var sessions: [TmuxSession] = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: Self.discoverTmuxSessions())
                }
            }

            // Enrich sessions with Claude CLI session data
            for i in sessions.indices {
                if let cwd = sessions[i].workingDirectory {
                    let claudeInfo = CLISessionReader.findActiveSession(workingDirectory: cwd)
                    sessions[i].claudeSessionId = claudeInfo?.sessionId
                    sessions[i].estimatedTokens = claudeInfo?.totalInputTokens
                    if let tokens = claudeInfo?.totalInputTokens {
                        sessions[i].pressureLevel = Self.pressureFromRealTokens(tokens)
                        sessions[i].estimatedTokens = tokens
                    }
                }
            }

            // Auto-manage: send /compact to high-pressure Claude sessions
            if shouldAutoManage {
                let sessionsToRotate = sessions.filter { session in
                    guard session.isClaudeSession,
                          let level = session.pressureLevel,
                          level.shouldRotate else { return false }
                    return true
                }

                for session in sessionsToRotate {
                    // Explicit MainActor hop — autoRotateTmuxSession reads/writes
                    // @MainActor state (tmuxRotationHistory, tmuxSessions).
                    await MainActor.run { [weak self] in
                        self?.autoRotateTmuxSession(session)
                    }
                }
            }

            let finalSessions = sessions
            await MainActor.run { [weak self] in
                self?.tmuxSessions = finalSessions
                // Prune stale rotation history entries to prevent unbounded growth
                self?.pruneRotationHistory()
            }
        }
    }

    /// Remove rotation history entries older than 1 hour or exceeding cap
    private func pruneRotationHistory() {
        guard tmuxRotationHistory.count > maxRotationHistorySize else { return }
        let oneHourAgo = Date().addingTimeInterval(-3600)
        tmuxRotationHistory = tmuxRotationHistory.filter { $0.value > oneHourAgo }
    }

    /// Send /compact to a tmux Claude session that's running hot.
    /// Respects cooldown to avoid spamming the same session.
    private func autoRotateTmuxSession(_ session: TmuxSession) {
        let now = Date()

        // Check cooldown — don't rotate the same session too frequently
        if let lastRotation = tmuxRotationHistory[session.name],
           now.timeIntervalSince(lastRotation) < rotationCooldown {
            return
        }

        // Only intervene if the session is idle (not mid-response).
        // If currentCommand is "claude", it's at the prompt (idle).
        // If it's something else (like "bash" running a subcommand), skip.
        guard session.currentCommand?.lowercased() == "claude" else { return }

        wtLog("[DaemonService] Auto-compacting tmux session '\(session.name)' — pressure \(session.pressureLevel?.rawValue ?? "unknown") (\(session.estimatedTokens ?? 0) tokens)")

        // Send /compact to trigger Claude's built-in context compaction
        let sent = Self.sendToTmux(session: session.name, keys: "/compact")
        if sent {
            tmuxRotationHistory[session.name] = now

            // Update the session's lastAutoCompact in our published list
            if let idx = tmuxSessions.firstIndex(where: { $0.name == session.name }) {
                tmuxSessions[idx].lastAutoCompact = now
            }

            // Log event if we have a branch ID (we don't for tmux, so use session name)
            EventStore.shared.log(
                branchId: "tmux:\(session.name)",
                sessionId: session.claudeSessionId,
                type: .sessionRotation,
                data: [
                    "source": "auto_tmux",
                    "session_name": session.name,
                    "estimated_tokens": session.estimatedTokens ?? 0,
                    "pressure": session.pressureLevel?.rawValue ?? "unknown",
                ]
            )
        }
    }

    /// Calculate pressure level from real token counts (more accurate than heuristic).
    nonisolated private static func pressureFromRealTokens(_ tokens: Int) -> PressureLevel {
        let ratio = Double(tokens) / Double(ContextPressureEstimator.maxContextTokens)
        switch ratio {
        case ..<0.5: return .low
        case 0.5..<0.75: return .moderate
        case 0.75..<0.9: return .high
        default: return .critical
        }
    }

    /// Resolved path to the tmux binary — checked once at startup across common install locations.
    nonisolated private static let tmuxExecutable: String = {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/opt/homebrew/bin/tmux"
    }()

    /// Runs `tmux list-panes -a` off the main thread for pane-level discovery.
    /// Groups panes by session, captures working directory and running command.
    nonisolated private static func discoverTmuxSessions() -> [TmuxSession] {
        let tmuxPath = tmuxExecutable
        guard FileManager.default.fileExists(atPath: tmuxPath) else { return [] }

        // Step 1: Get session-level data
        let sessionOutput = runTmux(tmuxPath, args: [
            "list-sessions", "-F",
            "#{session_name}||#{session_windows}||#{session_created}||#{session_attached}||#{session_activity}"
        ])
        guard let sessionOutput else { return [] }

        var sessionMap: [String: TmuxSession] = [:]
        for line in sessionOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = String(line).components(separatedBy: "||")
            guard fields.count >= 5 else { continue }

            let name = fields[0]
            sessionMap[name] = TmuxSession(
                name: name,
                windowCount: Int(fields[1]) ?? 0,
                createdAt: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0),
                isAttached: fields[3] == "1",
                lastActivity: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0)
            )
        }

        // Step 2: Get pane-level data (active pane per session)
        let paneOutput = runTmux(tmuxPath, args: [
            "list-panes", "-a", "-F",
            "#{session_name}||#{pane_current_path}||#{pane_current_command}||#{pane_pid}||#{pane_active}"
        ])

        if let paneOutput {
            for line in paneOutput.split(separator: "\n", omittingEmptySubsequences: true) {
                let fields = String(line).components(separatedBy: "||")
                guard fields.count >= 5 else { continue }

                let sessionName = fields[0]
                let isActive = fields[4] == "1"

                // Only take data from the active pane (or first if none active)
                if isActive || sessionMap[sessionName]?.workingDirectory == nil {
                    sessionMap[sessionName]?.workingDirectory = fields[1]
                    sessionMap[sessionName]?.currentCommand = fields[2]
                    sessionMap[sessionName]?.panePid = Int(fields[3])
                }
            }
        }

        return Array(sessionMap.values).sorted { $0.createdAt < $1.createdAt }
    }

    /// Helper to run tmux commands and return stdout.
    /// Uses readabilityHandler to drain pipes incrementally and avoids blocking
    /// cooperative threads (called from Task.detached on GCD utility queue).
    nonisolated private static func runTmux(_ path: String, args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        let accum = PipeAccumulator()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                pipe.fileHandleForReading.readabilityHandler = nil
            } else {
                accum.append(data)
            }
        }

        do {
            try proc.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        // Wait with timeout — this runs on a GCD queue (via Task.detached),
        // NOT on the cooperative thread pool, so semaphore is safe here.
        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + .seconds(10)) == .timedOut {
            proc.terminate()
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        guard proc.terminationStatus == 0 else { return nil }
        return String(data: accum.data, encoding: .utf8)
    }

    // MARK: - Tmux Commands

    /// Send keystrokes to a tmux session (for rotation commands, etc.)
    /// Fire-and-forget — tmux send-keys completes in <100ms, no need to wait.
    nonisolated static func sendToTmux(session: String, keys: String) -> Bool {
        let tmuxPath = tmuxExecutable
        guard FileManager.default.fileExists(atPath: tmuxPath) else { return false }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxPath)
        proc.arguments = ["send-keys", "-t", session, keys, "Enter"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            // Fire and forget with cleanup — tmux send-keys is near-instant.
            // terminationHandler ensures the Process object is properly cleaned up.
            proc.terminationHandler = { _ in /* cleanup */ }
            return true
        } catch {
            return false
        }
    }

    /// Send Ctrl+C to a tmux session to cancel the running command.
    nonisolated static func cancelTmuxSession(session: String) -> Bool {
        let tmuxPath = tmuxExecutable
        guard FileManager.default.fileExists(atPath: tmuxPath) else { return false }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxPath)
        proc.arguments = ["send-keys", "-t", session, "C-c"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.terminationHandler = { _ in /* cleanup */ }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Status

    func getStatus() async -> DaemonResponse? {
        do {
            return try await socket.send(.status)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Kill

    func killSession(_ taskId: String) async {
        do {
            _ = try await socket.send(.kill(taskId: taskId))
        } catch {
            lastError = error.localizedDescription
        }
    }
}

// MARK: - Health File Model

private struct DaemonHealthFile: Codable {
    let timestamp: TimeInterval
    let pid: Int?
    let uptime: TimeInterval?
}
