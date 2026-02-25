import Foundation

// MARK: - Thread-Safe One-Shot Guard

/// Thread-safe one-shot flag for guarding continuation resumes.
/// Wraps a Bool in a class so it can be captured by @Sendable closures.
final class OneShotGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false

    /// Returns true on the first call; false on all subsequent calls.
    func tryFire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _fired { return false }
        _fired = true
        return true
    }
}

// MARK: - Working Directory Resolution (shared by ClaudeBridge + AnthropicAPIProvider)

/// Resolves a working directory from an explicit path or project name.
/// Checks common ~/Development/<project> variants; falls back to ~/Development.
func resolveWorkingDirectory(_ explicit: String?, project: String?) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if let dir = explicit, FileManager.default.fileExists(atPath: dir) {
        return dir
    }
    if let project {
        let devRoot = "\(home)/Development"
        let candidates = [
            "\(devRoot)/\(project)",
            "\(devRoot)/\(project.lowercased())",
            "\(devRoot)/\(project.replacingOccurrences(of: " ", with: "-"))",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
    }
    return "\(FileManager.default.homeDirectoryForCurrentUser.path)/Development"
}

// MARK: - HTTP Helpers (shared by CanvasServer + PluginServer)

/// Extract the Content-Length value from raw HTTP headers.
func extractHTTPContentLength(from headers: String) -> Int {
    for line in headers.components(separatedBy: "\r\n") {
        if line.lowercased().hasPrefix("content-length:") {
            let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            return Int(val) ?? 0
        }
    }
    return 0
}

/// Escape a string for safe embedding in a JSON value.
/// Uses JSONSerialization for correct handling of all Unicode control characters.
func escapeJSONString(_ s: String) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: s),
       let json = String(data: data, encoding: .utf8) {
        // JSONSerialization wraps in quotes — strip them
        return String(json.dropFirst().dropLast())
    }
    // Fallback: manual escape for the common cases
    return s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
}
