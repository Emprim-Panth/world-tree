import Foundation

/// Persists security gate approvals across sessions.
/// Keyed by ToolGuard assessment reason string — same pattern = same key.
final class PermissionStore {
    static let shared = PermissionStore()

    private let defaults = UserDefaults.standard
    private let key = "com.worldtree.security.approved-patterns"
    private let lock = NSLock()

    private init() {}

    func isApproved(reason: String) -> Bool {
        let approved = defaults.stringArray(forKey: key) ?? []
        return approved.contains(reason)
    }

    func approve(reason: String) {
        lock.withLock {
            var approved = defaults.stringArray(forKey: key) ?? []
            guard !approved.contains(reason) else { return }
            approved.append(reason)
            defaults.set(approved, forKey: key)
        }
    }

    func revoke(reason: String) {
        lock.withLock {
            var approved = defaults.stringArray(forKey: key) ?? []
            approved.removeAll { $0 == reason }
            defaults.set(approved, forKey: key)
        }
    }

    func allApproved() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }
}
