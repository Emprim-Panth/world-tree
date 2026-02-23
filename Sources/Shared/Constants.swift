import Foundation

enum CortanaConstants {
    // MARK: - Database (Phase 2: Unified with Gateway)
    // Friday test database — isolated from production friday.db
    static let dropboxDatabasePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openclaude/state/world-tree.db"
    }()

    static let fallbackDatabasePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openclaude/state/world-tree.db"
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

    // MARK: - Friday Channel (daemon HTTP API, port 8765)
    static let daemonAPIURL = "http://localhost:8765"
    static let daemonAPITokenKey = "cortana.daemonAPIToken"
    static let fridayChannelEnabledKey = "cortana.fridayChannelEnabled"

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

    // MARK: - Remote Canvas (MacBook client mode)
    static let remoteCanvasEnabledKey = "cortana.remoteCanvasEnabled"
    static let remoteCanvasURLKey = "cortana.remoteCanvasURL"
    static let remoteCanvasTokenKey = "cortana.remoteCanvasToken"

    // MARK: - CLI
    static let claudeCliPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin/claude"
    }()
}
