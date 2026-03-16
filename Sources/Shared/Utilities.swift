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

// MARK: - HTTP Helpers (shared by WorldTreeServer + PluginServer)

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

/// Escape a string for safe embedding in a JSON string literal.
/// JSONSerialization only accepts arrays/dictionaries at the top level and will
/// throw an Objective-C exception for bare strings, so escape manually here.
func escapeJSONString(_ s: String) -> String {
    var escaped = String()
    escaped.reserveCapacity(s.count)

    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"":
            escaped += "\\\""
        case "\\":
            escaped += "\\\\"
        case "\u{08}":
            escaped += "\\b"
        case "\u{0C}":
            escaped += "\\f"
        case "\n":
            escaped += "\\n"
        case "\r":
            escaped += "\\r"
        case "\t":
            escaped += "\\t"
        default:
            if scalar.value < 0x20 {
                let hex = String(scalar.value, radix: 16, uppercase: true)
                escaped += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
    }

    return escaped
}
