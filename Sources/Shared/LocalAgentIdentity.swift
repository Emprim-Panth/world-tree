import Foundation

/// Reads the local openClaude agent identity from the daemon status file.
/// Falls back to "Friday" when the daemon is not running or the file is absent.
enum LocalAgentIdentity {
    private static let statusPath =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaude/state/daemon.status.json")
            .path

    /// The agent's display name (e.g. "Friday"). Evaluated once and cached.
    static let name: String = {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statusPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identity = json["identity"] as? String,
              !identity.isEmpty
        else { return "Friday" }
        return identity
    }()

    /// First character of the name, uppercased — used as the avatar initial.
    static var initial: String { String(name.prefix(1).uppercased()) }
}
