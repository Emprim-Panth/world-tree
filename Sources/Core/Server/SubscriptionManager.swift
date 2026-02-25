import Foundation

// MARK: - SubscriptionManager

/// Tracks which WebSocket clients are subscribed to which branches.
///
/// Rules (FRD-003):
/// - One subscription per client — subscribing to a new branch auto-unsubscribes from the previous.
/// - Provides O(1) branchId → [clientId] lookup for broadcasting.
/// - Cleans up all state when a client disconnects.
///
/// MainActor-confined because it is exclusively called from WorldTreeServer, which is @MainActor.
@MainActor
final class SubscriptionManager {
    static let shared = SubscriptionManager()

    /// clientId → branchId. One entry per subscribed client.
    private(set) var subscriptions: [String: String] = [:]

    /// branchId → Set<clientId>. Reverse index for O(1) broadcast lookup.
    private(set) var branchSubscribers: [String: Set<String>] = [:]

    /// Designated initialiser — internal so tests can create isolated instances.
    init() {}

    // MARK: - Mutation

    /// Subscribe `clientId` to `branchId`.
    /// If the client is already subscribed to a different branch, it is automatically unsubscribed first.
    func subscribe(clientId: String, branchId: String) {
        // Remove from previous branch if present
        if let previous = subscriptions[clientId], previous != branchId {
            branchSubscribers[previous]?.remove(clientId)
            if branchSubscribers[previous]?.isEmpty == true {
                branchSubscribers.removeValue(forKey: previous)
            }
        }

        subscriptions[clientId] = branchId
        branchSubscribers[branchId, default: []].insert(clientId)
    }

    /// Unsubscribe `clientId` from their current branch.
    /// No-op if the client has no active subscription.
    func unsubscribe(clientId: String) {
        guard let branchId = subscriptions.removeValue(forKey: clientId) else { return }
        branchSubscribers[branchId]?.remove(clientId)
        if branchSubscribers[branchId]?.isEmpty == true {
            branchSubscribers.removeValue(forKey: branchId)
        }
    }

    /// Remove a client entirely on disconnect. Equivalent to unsubscribe.
    func remove(clientId: String) {
        unsubscribe(clientId: clientId)
    }

    // MARK: - Queries

    /// Return all clientIds subscribed to `branchId`. Empty set if none.
    func subscribers(for branchId: String) -> Set<String> {
        branchSubscribers[branchId] ?? []
    }

    /// Return the branchId `clientId` is currently subscribed to, or nil.
    func subscribedBranch(for clientId: String) -> String? {
        subscriptions[clientId]
    }
}
