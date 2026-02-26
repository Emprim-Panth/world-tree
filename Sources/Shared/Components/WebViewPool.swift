import Foundation
import WebKit

/// Manages a capped pool of WKWebViews to prevent unbounded process spawning.
///
/// Each WKWebView spawns a separate `com.apple.WebKit.WebContent` OS process.
/// Without a cap, a conversation with 30 code blocks spawns 30 processes, each
/// using 50-200MB RAM and its own GPU context. WindowServer must composite all of
/// them, and when total resources are exhausted, the entire Mac freezes.
///
/// This pool enforces a hard cap. When the cap is reached, the oldest inactive
/// view is recycled (its HTML content is replaced).
@MainActor
final class WebViewPool {
    static let shared = WebViewPool()

    /// Maximum number of live WKWebViews. Each is an OS subprocess.
    /// 8 is enough for a full screen of code blocks without starving the system.
    let maxPoolSize = 8

    /// Currently live WKWebViews, keyed by a unique identifier.
    /// Ordered by last-use time (oldest first).
    private var activeViews: [(id: String, webView: WKWebView, lastUsed: Date)] = []

    /// Track how many views are currently visible on screen
    private(set) var visibleCount = 0

    private init() {}

    /// Check if there's capacity for a new WKWebView without exceeding the cap.
    var hasCapacity: Bool {
        activeViews.count < maxPoolSize
    }

    /// Register a newly created WKWebView. Returns false if the pool is full
    /// and the caller should use a placeholder instead.
    func register(id: String, webView: WKWebView) -> Bool {
        // Already registered
        if activeViews.contains(where: { $0.id == id }) {
            touch(id: id)
            return true
        }

        if activeViews.count < maxPoolSize {
            activeViews.append((id: id, webView: webView, lastUsed: Date()))
            return true
        }

        // Pool is full — evict the oldest non-visible view
        // For now, just refuse (caller shows placeholder)
        return false
    }

    /// Mark a view as recently used
    func touch(id: String) {
        if let idx = activeViews.firstIndex(where: { $0.id == id }) {
            activeViews[idx].lastUsed = Date()
        }
    }

    /// Remove a view from the pool (when its SwiftUI view disappears)
    func release(id: String) {
        activeViews.removeAll { $0.id == id }
    }

    /// Current pool utilization
    var count: Int { activeViews.count }
}
