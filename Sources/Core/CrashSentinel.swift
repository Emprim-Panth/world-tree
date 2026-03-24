import Foundation

/// Crash sentinel — detects abnormal exits by tracking app lifecycle state.
///
/// On launch: checks if previous session ended cleanly.
/// During run: writes heartbeat timestamps every 30s.
/// On quit: marks clean exit.
///
/// The heartbeat reads the sentinel file to detect crashes without .ips reports
/// (memory pressure kills, hangs, SwiftUI panics, unhandled async throws).
@MainActor
final class CrashSentinel {
    static let shared = CrashSentinel()

    private let sentinelPath: String
    private let logPath: String
    // DispatchSourceTimer is not affected by App Nap or RunLoop throttling,
    // unlike Timer.scheduledTimer which can be starved when the app is occluded.
    private var heartbeatSource: DispatchSourceTimer?
    private let launchedAt: String = ISO8601DateFormatter().string(from: Date())
    private var lastUserInputAt: String? = nil

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.cortana/worldtree"
        sentinelPath = "\(dir)/sentinel.json"
        logPath = "\(dir)/crash-log.jsonl"

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
    }

    /// Call on app launch. Returns crash info if previous session ended abnormally.
    func checkAndStart() -> CrashInfo? {
        let crashInfo = checkPreviousSession()

        if let crash = crashInfo {
            wtLog("[CrashSentinel] Previous session exited abnormally — launched: \(crash.previousLaunch), last heartbeat: \(crash.lastHeartbeat), PID: \(crash.pid)")
        }

        // Write "running" sentinel
        writeSentinel(state: "running")
        wtLog("[CrashSentinel] Started — sentinel at \(sentinelPath)")

        // Start heartbeat — write timestamp every 30s so the external watchdog
        // can detect hangs (sentinel timestamp stale > 20 min = frozen).
        // Uses DispatchSourceTimer instead of Timer.scheduledTimer because
        // Timer is throttled by App Nap when the app is occluded, causing
        // multi-minute gaps between heartbeats and false stall detections.
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(2))
        source.setEventHandler { [weak self] in
            // We scheduled on .main queue, so MainActor isolation is guaranteed.
            // MainActor.assumeIsolated avoids an unnecessary async hop.
            MainActor.assumeIsolated {
                self?.writeSentinel(state: "running")
            }
        }
        source.resume()
        heartbeatSource = source

        return crashInfo
    }

    /// Call whenever the user submits a message. Updates lastUserInputAt in the sentinel
    /// so the watchdog daemon can distinguish a stalled session from an idle user.
    func recordUserInput() {
        writeSentinel(state: "running", userInputAt: ISO8601DateFormatter().string(from: Date()))
    }

    /// Call on clean app exit (applicationWillTerminate or similar).
    func markCleanExit() {
        heartbeatSource?.cancel()
        heartbeatSource = nil
        writeSentinel(state: "clean")
    }

    // MARK: - Internal

    private func checkPreviousSession() -> CrashInfo? {
        guard FileManager.default.fileExists(atPath: sentinelPath),
              let data = FileManager.default.contents(atPath: sentinelPath),
              let json = try? JSONDecoder().decode(SentinelData.self, from: data) else {
            return nil
        }

        // If previous state was "running", the app didn't exit cleanly
        guard json.state == "running" else { return nil }

        let info = CrashInfo(
            previousLaunch: json.launchedAt,
            lastHeartbeat: json.updatedAt,
            pid: json.pid
        )

        // Log the crash event
        logCrash(info)

        return info
    }

    private func writeSentinel(state: String, userInputAt: String? = nil) {
        if let t = userInputAt { lastUserInputAt = t }
        let sentinel = SentinelData(
            state: state,
            pid: ProcessInfo.processInfo.processIdentifier,
            launchedAt: launchedAt,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            lastUserInputAt: lastUserInputAt
        )

        do {
            let data = try JSONEncoder().encode(sentinel)
            try data.write(to: URL(fileURLWithPath: sentinelPath), options: .atomic)
        } catch {
            wtLog("[CrashSentinel] Failed to write sentinel: \(error)")
        }
    }

    private func logCrash(_ info: CrashInfo) {
        let entry: [String: String] = [
            "event": "abnormal_exit",
            "previous_launch": info.previousLaunch,
            "last_heartbeat": info.lastHeartbeat,
            "previous_pid": "\(info.pid)",
            "detected_at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: entry),
           var line = String(data: data, encoding: .utf8) {
            line += "\n"
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(line.data(using: .utf8) ?? Data())
                    handle.closeFile()
                }
            } else {
                try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - Data Types

struct SentinelData: Codable {
    let state: String       // "running" or "clean"
    let pid: Int32
    let launchedAt: String
    let updatedAt: String
    let version: String
    var lastUserInputAt: String?  // Updated when user submits a message; watchdog uses this for idle detection
}

struct CrashInfo {
    let previousLaunch: String
    let lastHeartbeat: String
    let pid: Int32
}
