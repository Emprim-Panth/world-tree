import Foundation

/// High-level daemon operations — dispatch, status, session management.
/// Wraps DaemonSocket with published state for SwiftUI binding.
@MainActor
final class DaemonService: ObservableObject {
    static let shared = DaemonService()

    @Published var isConnected: Bool = false
    @Published var activeSessions: [DaemonSession] = []
    @Published var lastError: String?

    private let socket = DaemonSocket()
    private var healthTimer: Timer?

    private init() {}

    // MARK: - Lifecycle

    func startMonitoring() {
        checkHealth()
        Task { await refreshSessions() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkHealth()
                await self?.refreshSessions()
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
