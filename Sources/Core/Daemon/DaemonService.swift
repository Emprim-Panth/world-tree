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

    private let socket = DaemonSocket()
    private var healthTimer: Timer?

    private init() {}

    // MARK: - Lifecycle

    func startMonitoring() {
        checkHealth()
        Task {
            await refreshSessions()
            refreshTmuxSessions()
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkHealth()
                await self?.refreshSessions()
                self?.refreshTmuxSessions()
            }
        }
    }

    func stopMonitoring() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    // MARK: - Health

    func checkHealth() {
        // Quick check: does socket file exist?
        let available = FileManager.default.fileExists(atPath: CortanaConstants.daemonSocketPath)
        if !available {
            isConnected = false
            return
        }

        // Also check health file
        let healthPath = CortanaConstants.daemonHealthPath
        if let data = FileManager.default.contents(atPath: healthPath),
           let health = try? JSONDecoder().decode(DaemonHealthFile.self, from: data) {
            let age = Date().timeIntervalSince1970 - health.timestamp
            isConnected = age < 60 // Healthy if updated within last minute
        } else {
            isConnected = available
        }
    }

    // MARK: - Dispatch

    /// Dispatch a task to the daemon for execution.
    /// Returns the task ID on success.
    func dispatch(
        message: String,
        project: String,
        priority: String = "normal"
    ) async -> String? {
        do {
            let command = DaemonCommand.dispatch(
                message: message,
                project: project,
                priority: priority
            )
            let response = try await socket.send(command)
            lastError = response.error
            return response.taskId
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Sessions

    func refreshSessions() async {
        do {
            let response = try await socket.send(.sessions)
            lastError = response.error

            // Parse sessions from response.data (array of dictionaries)
            guard let anyCodable = response.data,
                  let rawArray = anyCodable.value as? [AnyCodable] else {
                activeSessions = []
                return
            }

            activeSessions = rawArray.compactMap { parseDaemonSession(from: $0) }
        } catch {
            lastError = error.localizedDescription
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
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            startedAt = formatter.date(from: isoString)
                ?? ISO8601DateFormatter().date(from: isoString)
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

    /// Discover active tmux sessions by shelling out to `tmux list-sessions`.
    func refreshTmuxSessions() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["tmux", "list-sessions", "-F",
                          "#{session_name}||#{session_windows}||#{session_created}||#{session_attached}||#{session_activity}"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            tmuxSessions = []
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            tmuxSessions = []
            return
        }

        tmuxSessions = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> TmuxSession? in
                let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                    .map { String($0) }
                // Format: name||windows||created||attached||activity
                // split by "|" with empty subsequences gives [name, "", windows, "", created, "", attached, "", activity]
                // Actually split(separator: "|") gives ["name","","windows","","created","","attached","","activity"]
                // Let's use a simpler approach
                let fields = String(line).components(separatedBy: "||")
                guard fields.count >= 5 else { return nil }

                let name = fields[0]
                let windowCount = Int(fields[1]) ?? 0
                let created = Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0)
                let isAttached = fields[3] == "1"
                let activity = Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0)

                return TmuxSession(
                    name: name,
                    windowCount: windowCount,
                    createdAt: created,
                    isAttached: isAttached,
                    lastActivity: activity
                )
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
