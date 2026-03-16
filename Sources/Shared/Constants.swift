import Foundation

enum AppConstants {
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
    }()

    // MARK: - Database
    static let databasePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cortana/claude-memory/conversations.db"
    }()

    // MARK: - Daemon (Cortana paths — degrades gracefully if socket absent)
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

    // MARK: - Plugin Server (Cortana plugin integration, port 9400)
    static let pluginServerEnabledKey = "cortana.pluginEnabled"
    static let codexMCPSyncEnabledKey = "cortana.codexMCPSyncEnabled"
    static let pluginManifestDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cortana/state/plugins"
    }()

    // MARK: - Daemon Channel (HTTP API, port 8765)
    static let daemonAPIURL = "http://localhost:8765"
    static let daemonAPITokenKey = "cortana.daemonAPIToken"
    static let daemonChannelEnabledKey = "cortana.fridayChannelEnabled"  // key string unchanged for UserDefaults compat

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
    static let defaultModel = "claude-sonnet-4-6"
    static let defaultProvider = "claude-code"
    static let defaultProjectName = "General"

    // MARK: - Remote Studio (MacBook client mode)
    static let remoteEnabledKey = "cortana.remoteCanvasEnabled"  // string kept for UserDefaults compat
    static let remoteURLKey = "cortana.remoteCanvasURL"
    static let remoteTokenKey = "cortana.remoteCanvasToken"

    // MARK: - CLI
    static let claudeCliPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin/claude"
    }()

    // MARK: - UserDefaults Keys
    // All bare UserDefaults key strings are defined here so they're refactored
    // in one place. Key STRING VALUES must never change — that would silently
    // reset saved user preferences.

    // Navigation / selection (AppState)
    static let lastSelectedTreeIdKey = "lastSelectedTreeId"
    static let lastSelectedBranchIdKey = "lastSelectedBranchId"
    /// Dictionary: treeId → branchId for the last-viewed branch per tree.
    static let lastBranchPerTreeKey = "lastBranchPerTree"
    static let simpleModeKey = "worldtree.simpleMode"

    // Sidebar (SidebarViewModel)
    static let sidebarSortOrderKey = "sidebarSortOrder"
    static let projectOrderKey = "projectOrder"

    // Simple mode (SimpleModeViewModel)
    static let simpleModeSortOrderKey = "simpleModeSortOrder"

    // Provider / model (DocumentEditorView, ClaudeBridge, SettingsView, ModelPickerButton)
    static let defaultModelKey = "defaultModel"
    static let extendedThinkingEnabledKey = "extendedThinkingEnabled"
    static let cortanaAutoRoutingEnabledKey = "cortana.autoRoutingEnabled"
    static let cortanaCrossCheckEnabledKey = "cortana.crossCheckEnabled"

    // Voice (SettingsView, DocumentEditorView)
    static let voiceAutoSpeakKey = "voiceAutoSpeak"
    static let voiceSpeedKey = "voiceSpeed"
    static let voicePitchKey = "voicePitch"

    // Security (ToolExecutor, SettingsView)
    static let fileWriteReviewEnabledKey = "fileWriteReviewEnabled"

    // File picker memory (SidebarView, ForkMenu)
    static let lastWorkingDirectoryKey = "lastWorkingDirectory"

    // Global hotkey (GlobalHotKey, SettingsView)
    static let globalHotKeyEnabledKey = "globalHotKeyEnabled"
    static let globalHotKeyCodeKey = "globalHotKeyCode"
    static let globalHotKeyModifiersKey = "globalHotKeyModifiers"

    // Project scanner (ProjectScanner)
    static let developmentDirectoryKey = "developmentDirectory"

    // Database / context (SettingsView)
    static let databasePathKey = "databasePath"
    static let contextDepthKey = "contextDepth"

    // WorldTree server (WorldTreeServer — keys moved here from WorldTreeServer)
    static let serverTokenKey = "cortana.serverToken"
    static let serverEnabledKey = "cortana.serverEnabled"
    static let bonjourEnabledKey = "cortana.bonjourEnabled"

    // Provider selection (ProviderManager)
    static let selectedProviderKey = "cortana.selectedProvider"

    // Auto-compact (SessionRotator, ContextInspectorView)
    static let autoCompactEnabledKey = "cortana.autoCompactEnabled"

    // Daemon API base URL override (DaemonChannel)
    static let daemonAPIBaseURLKey = "cortana.daemonAPIBaseURL"
}
