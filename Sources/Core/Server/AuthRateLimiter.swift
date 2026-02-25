import Foundation

// MARK: - AuthRateLimiter

/// In-memory rate limiter for failed authentication attempts.
///
/// Implements FRD-007: max 5 failures per IP per 60-second sliding window.
/// Returns `true` (blocked) when the limit is exceeded. Auto-cleans expired
/// windows on each check. Never logs the token — only IP + timestamp.
///
/// Thread-safety: must be accessed exclusively from MainActor (WorldTreeServer is @MainActor).
@MainActor
final class AuthRateLimiter {

    // MARK: - Configuration

    static let maxFailures: Int = 5
    static let windowSeconds: TimeInterval = 60

    // MARK: - State

    /// Maps remote IP → list of failure timestamps within the current window.
    private var windows: [String: [Date]] = [:]

    // MARK: - API

    /// Call when an authentication failure occurs for the given IP.
    /// Returns `true` if the IP is now rate-limited (429 should be returned to the client).
    @discardableResult
    func recordFailure(ip: String) -> Bool {
        let now = Date()
        purgeExpired(for: ip, now: now)
        windows[ip, default: []].append(now)
        let count = windows[ip]?.count ?? 0
        wtLog("[AuthRateLimiter] Auth failure from \(ip) — \(count)/\(Self.maxFailures) in window")
        return count >= Self.maxFailures
    }

    /// Returns `true` if the given IP is currently blocked (already hit the limit).
    func isBlocked(ip: String) -> Bool {
        let now = Date()
        purgeExpired(for: ip, now: now)
        return (windows[ip]?.count ?? 0) >= Self.maxFailures
    }

    /// Remove failure records older than the sliding window for a single IP.
    private func purgeExpired(for ip: String, now: Date) {
        guard var timestamps = windows[ip] else { return }
        timestamps = timestamps.filter { now.timeIntervalSince($0) < Self.windowSeconds }
        if timestamps.isEmpty {
            windows.removeValue(forKey: ip)
        } else {
            windows[ip] = timestamps
        }
    }

    /// Purge all expired windows across all IPs. Call periodically to prevent unbounded growth.
    func purgeAllExpired() {
        let now = Date()
        for ip in windows.keys {
            purgeExpired(for: ip, now: now)
        }
    }
}
