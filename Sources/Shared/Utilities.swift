import Foundation

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
func escapeJSONString(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
     .replacingOccurrences(of: "\n", with: "\\n")
     .replacingOccurrences(of: "\r", with: "\\r")
     .replacingOccurrences(of: "\t", with: "\\t")
}
