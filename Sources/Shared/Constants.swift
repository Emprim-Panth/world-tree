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

    static let databasePathKey = "databasePath"

    // MARK: - Defaults
    static let defaultContextDepth = 10
    static let defaultModel = "claude-sonnet-4-6"
    static let defaultProvider = "claude-code"
    static let defaultProjectName = "General"

    // MARK: - CLI
    static let claudeCliPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin/claude"
    }()
}
