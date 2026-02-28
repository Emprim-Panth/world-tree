import Foundation

/// Unix domain socket client for communicating with cortana-daemon.
/// Protocol: JSON line over AF_UNIX socket at ~/.cortana/daemon/cortana.sock
actor DaemonSocket {
    private let socketPath: String

    init(socketPath: String = AppConstants.daemonSocketPath) {
        self.socketPath = socketPath
    }

    /// Send a command to the daemon and receive a response
    func send(_ command: DaemonCommand) async throws -> DaemonResponse {
        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DaemonError.socketCreationFailed(errno: errno)
        }
        defer { close(fd) }

        // Connect
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                let dst = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
                let len = min(strlen(cstr) + 1, pathSize)
                memcpy(dst, cstr, len)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            throw DaemonError.connectionFailed(errno: errno)
        }

        // Set receive timeout — prevents indefinite blocking if daemon hangs
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Send JSON command — loop until all bytes are written (send may be partial)
        let encodedData = try JSONEncoder().encode(command)
        guard let jsonString = String(data: encodedData, encoding: .utf8) else {
            throw DaemonError.sendFailed(errno: EILSEQ)
        }
        let sendBytes = Array(jsonString.utf8) + [UInt8(ascii: "\n")]
        var totalSent = 0
        while totalSent < sendBytes.count {
            let sent = sendBytes.withUnsafeBufferPointer { ptr in
                Darwin.send(fd, ptr.baseAddress! + totalSent, sendBytes.count - totalSent, 0)
            }
            guard sent > 0 else {
                throw DaemonError.sendFailed(errno: errno)
            }
            totalSent += sent
        }

        // Read response — offload blocking recv to a GCD thread so we don't
        // stall the Swift concurrency cooperative thread pool.
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 65536)
                while true {
                    let received = Darwin.recv(fd, &chunk, chunk.count, 0)
                    if received <= 0 { break }
                    buffer.append(contentsOf: chunk[0..<received])
                    // Check if buffer contains a newline — return everything up to it
                    if let nlIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let messageData = Data(buffer[buffer.startIndex..<nlIndex])
                        if messageData.isEmpty {
                            continuation.resume(throwing: DaemonError.receiveFailed(errno: errno))
                        } else {
                            continuation.resume(returning: messageData)
                        }
                        return
                    }
                }
                if buffer.isEmpty {
                    continuation.resume(throwing: DaemonError.receiveFailed(errno: errno))
                } else {
                    // No newline found — try decoding whatever we got
                    continuation.resume(returning: buffer)
                }
            }
        }
        return try JSONDecoder().decode(DaemonResponse.self, from: responseData)
    }

    /// Check if daemon socket exists (quick health check)
    func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }
}

enum DaemonError: LocalizedError {
    case socketCreationFailed(errno: Int32)
    case connectionFailed(errno: Int32)
    case sendFailed(errno: Int32)
    case receiveFailed(errno: Int32)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let e): "Failed to create socket: \(String(cString: strerror(e)))"
        case .connectionFailed(let e): "Failed to connect to daemon: \(String(cString: strerror(e)))"
        case .sendFailed(let e): "Failed to send command: \(String(cString: strerror(e)))"
        case .receiveFailed(let e): "Failed to receive response: \(String(cString: strerror(e)))"
        case .invalidResponse: "Invalid response from daemon"
        }
    }
}
