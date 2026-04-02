import Foundation
import os.log

private let poolLog = Logger(subsystem: "com.forgeandcode.WorldTree", category: "SessionPool")

/// Tracks Harness session pool state by watching pool-state.json.
/// Provides observable session list for the Session Pool View.
@MainActor
@Observable
final class SessionPoolStore {
    static let shared = SessionPoolStore()

    // MARK: — Observable State

    var sessions: [PoolSession] = []
    var total: Int = 0
    var ready: Int = 0
    var busy: Int = 0
    var warming: Int = 0
    var maxSize: Int = 3
    var warmTarget: Int = 2
    var lastUpdate: Date?
    var isHarnessRunning: Bool = false

    // MARK: — Internal

    private var watcher: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private let stateFilePath: String
    private let healthFilePath: String
    private let pidFilePath: String

    private init() {
        let cortanaDir = NSHomeDirectory() + "/.cortana/harness"
        stateFilePath = cortanaDir + "/pool-state.json"
        healthFilePath = cortanaDir + "/.health"
        pidFilePath = cortanaDir + "/harness.pid"
    }

    // MARK: — Lifecycle

    func start() {
        refresh()
        startWatching()
        // Poll every 10 seconds as backup (file watcher may miss changes)
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
        loadPoolState()
    }

    private func checkHarnessRunning() {
        guard FileManager.default.fileExists(atPath: pidFilePath),
              let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr) else {
            isHarnessRunning = false
            return
        }
        // kill(pid, 0) returns 0 if process exists
        isHarnessRunning = kill(pid, 0) == 0
    }

    private func loadPoolState() {
        guard FileManager.default.fileExists(atPath: stateFilePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: stateFilePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sessions = []
            return
        }

        let config = json["config"] as? [String: Any]
        maxSize = config?["maxSize"] as? Int ?? 3
        warmTarget = config?["warmSize"] as? Int ?? 2

        guard let sessionsDict = json["sessions"] as? [String: [String: Any]] else {
            sessions = []
            return
        }

        var parsed: [PoolSession] = []
        for (id, info) in sessionsDict {
            parsed.append(PoolSession(
                id: id,
                tmuxName: info["tmuxName"] as? String ?? "",
                status: info["status"] as? String ?? "dead",
                project: info["project"] as? String,
                taskId: info["taskId"] as? String,
                pid: info["pid"] as? Int,
                createdAt: info["createdAt"] as? String,
                busySince: info["busySince"] as? String,
                lastActivity: info["lastActivity"] as? String
            ))
        }

        sessions = parsed.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
        total = sessions.count
        ready = sessions.filter { $0.status == "ready" }.count
        busy = sessions.filter { $0.status == "busy" }.count
        warming = sessions.filter { $0.status == "warming" }.count
        lastUpdate = Date()
    }

    // MARK: — File Watching

    private func startWatching() {
        // Watch the harness directory for changes to pool-state.json
        let dirPath = (stateFilePath as NSString).deletingLastPathComponent
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

        // Use a simple synchronous Unix socket call
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

                // Send command
                do {
                    let jsonData = try JSONSerialization.data(withJSONObject: command)
                    _ = jsonData.withUnsafeBytes { buf in
                        Darwin.write(fd, buf.baseAddress!, buf.count)
                    }
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                // Read response
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

    /// Send text to a specific session via harness.
    func sendToSession(sessionId: String, text: String) async -> Bool {
        let result = await sendCommand([
            "action": "send",
            "session_id": sessionId,
            "text": text
        ])
        return result?["ok"] as? Bool ?? false
    }

    /// Request a session for a project.
    func requestSession(project: String?) async -> [String: Any]? {
        var cmd: [String: Any] = ["action": "request"]
        if let project { cmd["project"] = project }
        return await sendCommand(cmd)
    }

    /// Release a session back to pool.
    func releaseSession(sessionId: String) async {
        _ = await sendCommand(["action": "release", "session_id": sessionId])
        refresh()
    }
}

// MARK: — Model

struct PoolSession: Identifiable, Hashable {
    let id: String
    let tmuxName: String
    let status: String
    let project: String?
    let taskId: String?
    let pid: Int?
    let createdAt: String?
    let busySince: String?
    let lastActivity: String?

    var statusColor: String {
        switch status {
        case "ready": return "green"
        case "busy": return "orange"
        case "warming": return "cyan"
        case "dead": return "red"
        default: return "gray"
        }
    }
}
