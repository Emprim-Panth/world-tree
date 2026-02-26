import Foundation

enum AppConstants {
    // MARK: - Database
    static let databasePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cortana/claude-memory/conversations.db"
    }()

    // MARK: - Daemon (OpenClaude paths — degrades gracefully if socket absent)
    static let daemonSocketPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openclaude/daemon/friday.sock"
    }()

    static let daemonHealthPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openclaude/daemon/.health"
    }()

    static let daemonLogsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openclaude/logs"
    }()

    // MARK: - Plugin Server (openClaude-swift integration, port 9400)
    static let pluginServerEnabledKey = "cortana.pluginEnabled"
    static let pluginManifestDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openclaude/state/plugins"
    }()

    // MARK: - Daemon Channel (HTTP API, port 8765)
    static let daemonAPIURL = "http://localhost:8765"
    static let daemonAPITokenKey = "cortana.daemonAPIToken"
    static let daemonChannelEnabledKey = "cortana.fridayChannelEnabled"  // key string unchanged for UserDefaults compat

    // MARK: - Activity
    static let activityDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openclaude/activity"
    }()

    static let completedMarkersDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openclaude/daemon"
    }()

    // MARK: - Defaults
    static let defaultContextDepth = 10
    static let defaultModel = "claude-sonnet-4-6"
    static let defaultProvider = "claude-code"

    // MARK: - Remote Studio (MacBook client mode)
    static let remoteEnabledKey = "cortana.remoteCanvasEnabled"  // string kept for UserDefaults compat
    static let remoteURLKey = "cortana.remoteCanvasURL"
    static let remoteTokenKey = "cortana.remoteCanvasToken"

    // MARK: - CLI
    static let claudeCliPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin/claude"
    }()
}
