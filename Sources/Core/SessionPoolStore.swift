import Foundation
import os.log

private let poolLog = Logger(subsystem: "com.forgeandcode.WorldTree", category: "Dispatcher")

/// Tracks Harness dispatcher + interactive session state by watching JSON files.
/// Provides observable state for the Dispatcher View.
@MainActor
@Observable
final class SessionPoolStore {
    static let shared = SessionPoolStore()

    // MARK: — Observable State

    /// Headless tasks running via `claude -p`
    var runningTasks: [DispatcherTask] = []
    /// Tasks waiting for capacity
    var queuedCount: Int = 0
    /// Recently completed tasks
    var recentCompleted: [CompletedTask] = []
    /// Interactive tmux sessions (for Evan's direct use)
    var interactiveSessions: [InteractiveSession] = []

    var maxConcurrent: Int = 3
    var lastUpdate: Date?
    var isHarnessRunning: Bool = false

    // Convenience
    var runningCount: Int { runningTasks.count }
    var completedCount: Int { recentCompleted.filter { $0.status == "completed" }.count }
    var failedCount: Int { recentCompleted.filter { $0.status == "failed" }.count }

    // MARK: — Internal

    private var watcher: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private let dispatcherStatePath: String
    private let interactiveStatePath: String
    private let pidFilePath: String

    private init() {
        let cortanaDir = NSHomeDirectory() + "/.cortana/harness"
        dispatcherStatePath = cortanaDir + "/dispatcher-state.json"
        interactiveStatePath = cortanaDir + "/interactive-sessions.json"
        pidFilePath = cortanaDir + "/harness.pid"
    }

    // MARK: — Lifecycle

    func start() {
        refresh()
        startWatching()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: — Data

    func refresh() {
        checkHarnessRunning()
        loadDispatcherState()
        loadInteractiveState()
        lastUpdate = Date()
    }

    private func checkHarnessRunning() {
        guard FileManager.default.fileExists(atPath: pidFilePath),
              let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr) else {
            isHarnessRunning = false
            return
        }
        isHarnessRunning = kill(pid, 0) == 0
    }

    private func loadDispatcherState() {
        guard FileManager.default.fileExists(atPath: dispatcherStatePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: dispatcherStatePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            runningTasks = []
            queuedCount = 0
            recentCompleted = []
            return
        }

        let config = json["config"] as? [String: Any]
        maxConcurrent = config?["maxConcurrent"] as? Int ?? 3

        // Running tasks
        if let running = json["running"] as? [[String: Any]] {
            runningTasks = running.map { info in
                DispatcherTask(
                    id: info["id"] as? String ?? "",
                    status: info["status"] as? String ?? "running",
                    agent: info["agent"] as? String,
                    agentRole: info["agentRole"] as? String,
                    project: info["project"] as? String ?? "",
                    model: info["model"] as? String ?? "sonnet",
                    startedAt: info["startedAt"] as? String,
                    pid: info["pid"] as? Int
                )
            }
        } else {
            runningTasks = []
        }

        // Queued
        if let queued = json["queued"] as? [[String: Any]] {
            queuedCount = queued.count
        } else {
            queuedCount = 0
        }

        // Recent completed
        if let completed = json["recentCompleted"] as? [[String: Any]] {
            recentCompleted = completed.map { info in
                CompletedTask(
                    id: info["id"] as? String ?? "",
                    status: info["status"] as? String ?? "completed",
                    agent: info["agent"] as? String,
                    project: info["project"] as? String ?? "",
                    exitCode: info["exitCode"] as? Int,
                    costUsd: info["costUsd"] as? Double,
                    startedAt: info["startedAt"] as? String,
                    completedAt: info["completedAt"] as? String,
                    toolCount: info["toolCount"] as? Int ?? 0
                )
            }
        } else {
            recentCompleted = []
        }
    }

    private func loadInteractiveState() {
        guard FileManager.default.fileExists(atPath: interactiveStatePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: interactiveStatePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = json["sessions"] as? [String: [String: Any]] else {
            interactiveSessions = []
            return
        }

        interactiveSessions = sessions.map { (id, info) in
            InteractiveSession(
                id: id,
                tmuxName: info["tmuxName"] as? String ?? "",
                project: info["project"] as? String,
                model: info["model"] as? String ?? "sonnet",
                createdAt: info["createdAt"] as? String
            )
        }.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
    }

    // MARK: — File Watching

    private func startWatching() {
        let dirPath = (dispatcherStatePath as NSString).deletingLastPathComponent
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    // MARK: — Commands (via Harness socket)

    func sendCommand(_ command: [String: Any]) async -> [String: Any]? {
        let socketPath = NSHomeDirectory() + "/.cortana/harness/harness.sock"
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { close(fd) }

                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                    socketPath.withCString { cStr in
                        _ = memcpy(ptr, cStr, min(socketPath.utf8.count, 104))
                    }
                }

                let connectResult = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }

                guard connectResult == 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    let jsonData = try JSONSerialization.data(withJSONObject: command)
                    _ = jsonData.withUnsafeBytes { buf in
                        Darwin.write(fd, buf.baseAddress!, buf.count)
                    }
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                var response = Data()
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    let bytesRead = Darwin.read(fd, &buffer, buffer.count)
                    if bytesRead <= 0 { break }
                    response.append(contentsOf: buffer[..<bytesRead])
                }

                let result = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
                continuation.resume(returning: result)
            }
        }
    }

    /// Dispatch a task headlessly.
    func dispatchTask(message: String, project: String, model: String? = nil) async -> [String: Any]? {
        var cmd: [String: Any] = ["action": "dispatch", "message": message, "project": project]
        if let model { cmd["model"] = model }
        return await sendCommand(cmd)
    }

    /// Cancel a running or queued task.
    func cancelTask(taskId: String) async -> Bool {
        let result = await sendCommand(["action": "cancel", "task_id": taskId])
        refresh()
        return result?["ok"] as? Bool ?? false
    }

    /// Request an interactive session for a project.
    func requestSession(project: String?, model: String? = nil) async -> [String: Any]? {
        var cmd: [String: Any] = ["action": "request"]
        if let project { cmd["project"] = project }
        if let model { cmd["model"] = model }
        return await sendCommand(cmd)
    }

    /// Release an interactive session.
    func releaseSession(sessionId: String) async {
        _ = await sendCommand(["action": "release", "session_id": sessionId])
        refresh()
    }
}

// MARK: — Models

struct DispatcherTask: Identifiable, Hashable {
    let id: String
    let status: String
    let agent: String?
    let agentRole: String?
    let project: String
    let model: String
    let startedAt: String?
    let pid: Int?

    var displayName: String {
        if let agent { return "\(agent) (\(agentRole ?? "agent"))" }
        return "Direct task"
    }

    var statusColor: String {
        switch status {
        case "running": return "orange"
        case "queued": return "cyan"
        default: return "gray"
        }
    }
}

struct CompletedTask: Identifiable, Hashable {
    let id: String
    let status: String
    let agent: String?
    let project: String
    let exitCode: Int?
    let costUsd: Double?
    let startedAt: String?
    let completedAt: String?
    let toolCount: Int

    var isSuccess: Bool { status == "completed" }
}

struct InteractiveSession: Identifiable, Hashable {
    let id: String
    let tmuxName: String
    let project: String?
    let model: String
    let createdAt: String?
}
