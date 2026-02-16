import Foundation

enum CortanaConstants {
    // MARK: - Database (Phase 2: Unified with Gateway)
    static let dropboxDatabasePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Phase 2: Now using unified gateway database
        return "\(home)/.cortana/cortana.db"
    }()

    static let fallbackDatabasePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cortana/cortana.db"
    }()

    // MARK: - Daemon
    static let daemonSocketPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cortana/daemon/cortana.sock"
    }()

    static let daemonHealthPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cortana/daemon/.health"
    }()

    static let daemonLogsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cortana/logs"
    }()

    // MARK: - Activity
    static let activityDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cortana/activity"
    }()

    static let completedMarkersDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cortana/daemon"
    }()

    // MARK: - Defaults
    static let defaultContextDepth = 10
    static let defaultModel = "claude-sonnet-4-5-20250929"
    static let defaultProvider = "claude-code"

    // MARK: - CLI
    static let claudeCliPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin/claude"
    }()
}
