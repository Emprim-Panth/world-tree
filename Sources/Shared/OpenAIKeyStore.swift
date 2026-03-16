import Foundation

enum OpenAIKeyStore {
    private static let envKey = "OPENAI_API_KEY"
    private static let keychainKey = "openai_api_key"

    static var hasEnvironmentKey: Bool {
        let value = ProcessInfo.processInfo.environment[envKey] ?? ""
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var hasKeychainKey: Bool {
        KeychainHelper.load(key: keychainKey) != nil
    }

    static var isConfigured: Bool {
        resolveAPIKey() != nil
    }

    static func resolveAPIKey() -> String? {
        let envValue = ProcessInfo.processInfo.environment[envKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !envValue.isEmpty {
            return envValue
        }

        if let keychainValue = KeychainHelper.load(key: keychainKey) {
            return keychainValue
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let keyFile = "\(home)/.openai/api_key"
        let fileValue = ((try? String(contentsOfFile: keyFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fileValue.isEmpty ? nil : fileValue
    }

    static func saveAPIKey(_ key: String) {
        KeychainHelper.save(key: keychainKey, value: key)
    }

    static func clearAPIKey() {
        KeychainHelper.delete(key: keychainKey)
    }
}
