import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - PeekabooBridgeServer
//
// Implements the Peekaboo Bridge protocol over a Unix domain socket so the
// peekaboo CLI can route screen capture through World Tree's existing TCC
// Screen Recording grant.
//
// Socket path: ~/Library/Application Support/Claude/bridge.sock
// Peekaboo checks that path automatically (one of its built-in candidates).
//
// Protocol: newline-delimited JSON.  Each request/response is one JSON object
// followed by a single '\n' byte.  The outer key is the Swift enum case name
// (Swift Codable enum convention: { "caseName": { "_0": { ...fields } } }).

final class PeekabooBridgeServer {
    static let shared = PeekabooBridgeServer()

    private let socketPath: String
    private var serverFD: Int32 = -1
    private(set) var isRunning = false
    private let lock = NSLock()
    private let connectionSemaphore = DispatchSemaphore(value: 16)

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let claudeDir = appSupport.appendingPathComponent("Claude")
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        socketPath = claudeDir.appendingPathComponent("bridge.sock").path
    }

    // MARK: - Lifecycle

    func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        lock.unlock()

        // Clean up stale socket from a previous run.
        try? FileManager.default.removeItem(atPath: socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            wtLog("[PeekabooBridge] socket() failed errno=\(errno)")
            return
        }

        // Copy socket path into sun_path (fixed-length C char tuple).
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { pathBuf in
            let bytes = Array(socketPath.utf8)
            precondition(bytes.count < pathBuf.count, "Bridge socket path too long")
            for (i, b) in bytes.enumerated() { pathBuf[i] = b }
            pathBuf[bytes.count] = 0
        }

        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard bindRC == 0 else {
            wtLog("[PeekabooBridge] bind() failed errno=\(errno)")
            close(fd); return
        }
        guard listen(fd, 8) == 0 else {
            wtLog("[PeekabooBridge] listen() failed errno=\(errno)")
            close(fd); return
        }

        lock.lock()
        serverFD = fd
        isRunning = true
        lock.unlock()

        wtLog("[PeekabooBridge] Ready at \(socketPath)")

        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        lock.lock()
        isRunning = false
        let fdToClose = serverFD
        serverFD = -1
        lock.unlock()

        if fdToClose >= 0 { close(fdToClose) }
        try? FileManager.default.removeItem(atPath: socketPath)
        wtLog("[PeekabooBridge] Stopped")
    }

    // MARK: - Accept Loop  (background thread)

    private func acceptLoop() {
        while true {
            lock.lock()
            let running = isRunning
            let currentFD = serverFD
            lock.unlock()
            guard running else { break }

            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.stride)
            // accept() blocks; lock must NOT be held here.
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(currentFD, $0, &clientLen)
                }
            }
            guard clientFD >= 0 else { continue }
            connectionSemaphore.wait()
            Thread.detachNewThread { [weak self] in
                guard let self else {
                    close(clientFD)
                    return
                }
                self.handleClient(fd: clientFD)
            }
        }
    }

    // MARK: - Client Handler  (background thread)

    private func handleClient(fd: Int32) {
        defer { connectionSemaphore.signal(); close(fd) }
        wtLog("[PeekabooBridge] Client connected fd=\(fd)")

        // Set a 30-second read timeout to prevent stale connections from holding semaphore slots
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)

        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { break }
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]) }

            // Peekaboo sends raw JSON with no newline terminator — it writes the
            // object then holds the connection open waiting for our response.
            // After each read, try to parse whatever we have as a complete JSON
            // object. On success, dispatch and clear the buffer for the next message.
            if !buffer.isEmpty,
               let json = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any]
            {
                buffer.removeAll()
                tryDispatch(json, fd: fd)
            }

            if n == 0 { break }  // peer closed
        }

        wtLog("[PeekabooBridge] Client disconnected fd=\(fd)")
    }

    private func tryDispatch(_ json: [String: Any], fd: Int32) {
        // Log every incoming request for diagnostics.
        let keys = json.keys.sorted().joined(separator: ", ")
        let logLine = "[PeekabooBridge] ← \(keys)\n"
        try? logLine.appendToFile(atPath: "/tmp/peekaboo_bridge.log")
        wtLog("[PeekabooBridge] ← \(keys)")

        guard let responseData = dispatch(json) else { return }
        var toSend = responseData
        toSend.append(UInt8(ascii: "\n"))
        toSend.withUnsafeBytes { ptr in _ = write(fd, ptr.baseAddress!, ptr.count) }
    }

    // MARK: - Dispatch

    private func dispatch(_ json: [String: Any]) -> Data? {
        if let box = json["handshake"] as? [String: Any], let inner = box["_0"] as? [String: Any] {
            return respondHandshake(inner)
        }
        if json["permissionsStatus"] != nil {
            return respondPermissions()
        }
        if json["captureScreen"] != nil || json["captureFrontmost"] != nil {
            return captureSync(windowID: nil, bundleID: nil)
        }
        if let box = json["captureWindow"] as? [String: Any],
           let inner = box["_0"] as? [String: Any]
        {
            let wid = (inner["windowID"] as? Int).map { CGWindowID($0) }
            let bid = inner["appBundleIdentifier"] as? String
            return captureSync(windowID: wid, bundleID: bid)
        }
        wtLog("[PeekabooBridge] Unhandled request keys: \(json.keys.sorted().joined(separator: ", "))")
        return nil
    }

    // MARK: - Handshake / Permissions

    private func respondHandshake(_: [String: Any]) -> Data? {
        let payload: [String: Any] = [
            "handshake": [
                "_0": [
                    "negotiatedVersion": ["major": 1, "minor": 0],
                    "hostKind": "gui",
                    "supportedOperations": [
                        "captureScreen",
                        "captureWindow",
                        "captureFrontmost",
                        "permissionsStatus",
                    ],
                    "permissions": [
                        "screenRecording": true,
                        "accessibility": false,
                        "appleScript": false,
                    ],
                    "permissionTags": [String: Any](),
                ],
            ],
        ]
        wtLog("[PeekabooBridge] Handshake complete — bridge active")
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private func respondPermissions() -> Data? {
        let payload: [String: Any] = [
            "permissionsStatus": [
                "_0": ["screenRecording": true, "accessibility": false, "appleScript": false],
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Screen Capture
    //
    // ScreenCaptureKit runs within the World Tree process, which already has
    // TCC Screen Recording permission. Bridges the async SCScreenshotManager
    // API to a synchronous call for the socket handler thread.

    private func captureSync(windowID: CGWindowID?, bundleID: String?) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?

        // Task.detached prevents cancellation propagation from any parent task context.
        // SCK APIs work from any thread.
        Task.detached { [weak self] in
            guard let self else { sem.signal(); return }
            do {
                let content = try await SCShareableContent.current
                let cgImage = try await self.pickAndCapture(
                    content: content, windowID: windowID, bundleID: bundleID)
                result = self.encodeCapture(cgImage)
            } catch {
                let msg = "[PeekabooBridge] SCK capture error: \(error)"
                wtLog(msg)
                try? (msg + "\n").appendToFile(atPath: "/tmp/peekaboo_bridge.log")
                result = self.respondError("captureFailed", error.localizedDescription)
            }
            sem.signal()
        }

        let timeout = DispatchTime.now() + .seconds(15)
        if sem.wait(timeout: timeout) == .timedOut {
            wtLog("[PeekabooBridge] Capture timed out after 15 s")
            return respondError("captureFailed", "Capture timed out")
        }
        return result
    }

    private func pickAndCapture(
        content: SCShareableContent,
        windowID: CGWindowID?,
        bundleID: String?
    ) async throws -> CGImage {
        let cfg = SCStreamConfiguration()

        if let wid = windowID,
           let win = content.windows.first(where: { $0.windowID == wid })
        {
            cfg.width  = max(1, Int(win.frame.width  * 2))
            cfg.height = max(1, Int(win.frame.height * 2))
            let filter = SCContentFilter(desktopIndependentWindow: win)
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg)
        }

        if let bid = bundleID,
           let win = content.windows.first(where: {
               $0.owningApplication?.bundleIdentifier == bid
           })
        {
            cfg.width  = max(1, Int(win.frame.width  * 2))
            cfg.height = max(1, Int(win.frame.height * 2))
            let filter = SCContentFilter(desktopIndependentWindow: win)
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg)
        }

        // Full primary display.
        guard let display = content.displays.first else {
            throw NSError(domain: "PeekabooBridge", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No displays available"])
        }
        cfg.width  = display.width
        cfg.height = display.height
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: cfg)
    }

    private func encodeCapture(_ cgImage: CGImage) -> Data? {
        // Use CGImageDestination — more robust than NSBitmapImageRep for SCKit images.
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, "public.png" as CFString, 1, nil)
        else {
            let m = "[PeekabooBridge] CGImageDestination creation failed"
            wtLog(m); try? (m + "\n").appendToFile(atPath: "/tmp/peekaboo_bridge.log")
            return respondError("encodingFailed", m)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            let m = "[PeekabooBridge] CGImageDestination finalize failed"
            wtLog(m); try? (m + "\n").appendToFile(atPath: "/tmp/peekaboo_bridge.log")
            return respondError("encodingFailed", m)
        }
        let pngData = mutableData as Data

        let tmpPath = "/tmp/peekaboo_\(Int(Date().timeIntervalSince1970 * 1000)).png"
        try? pngData.write(to: URL(fileURLWithPath: tmpPath))

        // Field names match PeekabooAutomationKit.CaptureResult: imageData (Data→base64),
        // filePath (String), capturedAt (ISO8601 String).
        let iso = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "capture": [
                "_0": [
                    "imageData": pngData.base64EncodedString(),
                    "filePath": tmpPath,
                    "capturedAt": iso.string(from: Date()),
                ],
            ],
        ]
        let msg = "[PeekabooBridge] Captured \(cgImage.width)×\(cgImage.height) → \(tmpPath)"
        wtLog(msg)
        try? (msg + "\n").appendToFile(atPath: "/tmp/peekaboo_bridge.log")
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Window Lookup

    private func frontWindowIDForBundle(_ bundleID: String) -> CGWindowID? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[CFString: Any]]
        else { return nil }

        for info in list {
            guard
                let pid = info[kCGWindowOwnerPID] as? Int,
                NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == bundleID,
                let wid = info[kCGWindowNumber] as? Int
            else { continue }
            return CGWindowID(wid)
        }
        return nil
    }

    // MARK: - Error Helper

    private func respondError(_ code: String, _ message: String) -> Data? {
        let payload: [String: Any] = ["error": ["_0": ["code": code, "message": message]]]
        return try? JSONSerialization.data(withJSONObject: payload)
    }
}

private extension String {
    func appendToFile(atPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        if let data = data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path),
               let fh = try? FileHandle(forWritingTo: url)
            {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                try data.write(to: url)
            }
        }
    }
}
