import Foundation

/// Unix domain socket client for communicating with cortana-daemon.
/// Protocol: JSON line over AF_UNIX socket at ~/.cortana/daemon/cortana.sock
actor DaemonSocket {
    private let socketPath: String

    init(socketPath: String = CortanaConstants.daemonSocketPath) {
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

        // Send JSON command
        let data = try JSONEncoder().encode(command)
        let jsonString = String(data: data, encoding: .utf8)! + "\n"
        let sent = jsonString.withCString { ptr in
            Darwin.send(fd, ptr, jsonString.utf8.count, 0)
        }
        guard sent > 0 else {
            throw DaemonError.sendFailed(errno: errno)
        }

        // Read response
        var buffer = [UInt8](repeating: 0, count: 65536)
        let received = Darwin.recv(fd, &buffer, buffer.count, 0)
        guard received > 0 else {
            throw DaemonError.receiveFailed(errno: errno)
        }

        let responseData = Data(buffer[0..<received])
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
