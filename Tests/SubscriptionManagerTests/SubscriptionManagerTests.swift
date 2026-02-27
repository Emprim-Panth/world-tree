import XCTest
@testable import WorldTree

// MARK: - SubscriptionManagerTests

/// Verifies the three core behaviours of SubscriptionManager (FRD-003):
///   1. subscribe  — client → branch mapping is created; auto-unsubscribes from previous branch
///   2. unsubscribe — mapping is removed; remove() on disconnect cleans up
///   3. broadcast   — subscribers(for:) returns all clients subscribed to a branch
@MainActor
final class SubscriptionManagerTests: XCTestCase {

    var manager: SubscriptionManager!

    override func setUp() {
        super.setUp()
        // Fresh instance per test — avoids shared state pollution
        manager = SubscriptionManager()
    }

    // MARK: - 1. Subscribe

    func testSubscribeCreatesMapping() {
        let clientId = "client-A"
        let branchId = "branch-1"

        manager.subscribe(clientId: clientId, branchId: branchId)

        XCTAssertEqual(manager.subscribedBranch(for: clientId), branchId,
                       "subscribedBranch(for:) must return the subscribed branchId")
        XCTAssertTrue(manager.subscribers(for: branchId).contains(clientId),
                      "subscribers(for:) must include the client")
    }

    func testSubscribeAutoUnsubscribesFromPreviousBranch() {
        let clientId = "client-B"
        let branch1 = "branch-2"
        let branch2 = "branch-3"

        manager.subscribe(clientId: clientId, branchId: branch1)
        manager.subscribe(clientId: clientId, branchId: branch2)

        // New subscription reflected
        XCTAssertEqual(manager.subscribedBranch(for: clientId), branch2,
                       "Client must be moved to the new branch")
        // Old branch cleaned up
        XCTAssertFalse(manager.subscribers(for: branch1).contains(clientId),
                       "Client must be removed from the previous branch")
        XCTAssertNil(manager.branchSubscribers[branch1],
                     "Empty subscriber sets must be removed from the index")
        // New branch populated
        XCTAssertTrue(manager.subscribers(for: branch2).contains(clientId),
                      "Client must appear in the new branch's subscriber set")
    }

    // MARK: - 2. Unsubscribe / Remove on Disconnect

    func testUnsubscribeClearsMapping() {
        let clientId = "client-C"
        let branchId = "branch-4"

        manager.subscribe(clientId: clientId, branchId: branchId)
        manager.unsubscribe(clientId: clientId)

        XCTAssertNil(manager.subscribedBranch(for: clientId),
                     "subscribedBranch must be nil after unsubscribe")
        XCTAssertFalse(manager.subscribers(for: branchId).contains(clientId),
                       "Client must no longer appear in branch subscribers")
        XCTAssertNil(manager.branchSubscribers[branchId],
                     "Empty subscriber set must be removed from the index")
    }

    func testRemoveOnDisconnectCleansUpSubscription() {
        let clientId = "client-D"
        let branchId = "branch-5"

        manager.subscribe(clientId: clientId, branchId: branchId)
        manager.remove(clientId: clientId)

        XCTAssertNil(manager.subscribedBranch(for: clientId),
                     "remove() must clear the client's subscription")
        XCTAssertNil(manager.branchSubscribers[branchId],
                     "Empty branch entry must be removed after disconnect")
    }

    // MARK: - 3. Broadcast Lookup

    func testSubscribersForBranchReturnsAllSubscribedClients() {
        let branchId = "branch-6"
        let clients = ["client-E", "client-F", "client-G"]

        for id in clients {
            manager.subscribe(clientId: id, branchId: branchId)
        }

        let result = manager.subscribers(for: branchId)
        XCTAssertEqual(result.count, clients.count,
                       "All subscribed clients must be returned for broadcasting")
        for id in clients {
            XCTAssertTrue(result.contains(id), "subscribers(for:) must contain \(id)")
        }
    }

    func testSubscribersForEmptyBranchReturnsEmptySet() {
        let result = manager.subscribers(for: "branch-nobody")
        XCTAssertTrue(result.isEmpty,
                      "subscribers(for:) must return an empty set for an unknown branch")
    }

    // MARK: - 4. Remove Client with Multiple Branch History

    /// Subscribe a client to branch A then branch B (auto-switch), then remove.
    /// Both branches must be fully clean — no dangling entries in either index.
    func testRemoveClientClearsAllState() {
        let clientId = "client-H"
        let branchA = "branch-7"
        let branchB = "branch-8"

        // Subscribe to A, then switch to B (auto-unsubscribes from A)
        manager.subscribe(clientId: clientId, branchId: branchA)
        manager.subscribe(clientId: clientId, branchId: branchB)

        // Precondition: client is on B, A is already empty
        XCTAssertEqual(manager.subscribedBranch(for: clientId), branchB)
        XCTAssertNil(manager.branchSubscribers[branchA],
                     "Branch A should already be cleaned up after auto-switch")

        // Now disconnect
        manager.remove(clientId: clientId)

        // Both branches must be empty
        XCTAssertNil(manager.subscribedBranch(for: clientId),
                     "Client subscription must be nil after remove")
        XCTAssertNil(manager.branchSubscribers[branchA],
                     "Branch A must have no subscriber entry after remove")
        XCTAssertNil(manager.branchSubscribers[branchB],
                     "Branch B must have no subscriber entry after remove")
        XCTAssertTrue(manager.subscriptions.isEmpty,
                      "subscriptions dict must be empty — only client was removed")
        XCTAssertTrue(manager.branchSubscribers.isEmpty,
                      "branchSubscribers dict must be empty — all branches cleared")
    }

    // MARK: - 5. Resubscribe Idempotency

    /// Subscribing the same client to the same branch twice must be a no-op
    /// (no duplicate entries, no crashes).
    func testResubscribeSameBranchIsIdempotent() {
        let clientId = "client-I"
        let branchId = "branch-9"

        manager.subscribe(clientId: clientId, branchId: branchId)
        manager.subscribe(clientId: clientId, branchId: branchId)

        XCTAssertEqual(manager.subscribers(for: branchId).count, 1,
                       "Subscribing twice to the same branch must not create duplicates")
        XCTAssertEqual(manager.subscribedBranch(for: clientId), branchId)
    }

    // MARK: - 6. Unsubscribe No-Op for Unknown Client

    /// Unsubscribing a client that was never subscribed must not crash or corrupt state.
    func testUnsubscribeUnknownClientIsNoop() {
        manager.unsubscribe(clientId: "phantom-client")

        XCTAssertTrue(manager.subscriptions.isEmpty,
                      "Unsubscribing an unknown client must not create entries")
        XCTAssertTrue(manager.branchSubscribers.isEmpty,
                      "Unsubscribing an unknown client must not create branch entries")
    }

    // MARK: - 7. Remove Preserves Other Clients

    /// When one client is removed, other clients on the same branch must be unaffected.
    func testRemoveClientPreservesOtherSubscribers() {
        let branchId = "branch-10"
        let clientA = "client-J"
        let clientB = "client-K"
        let clientC = "client-L"

        manager.subscribe(clientId: clientA, branchId: branchId)
        manager.subscribe(clientId: clientB, branchId: branchId)
        manager.subscribe(clientId: clientC, branchId: branchId)

        // Remove one client
        manager.remove(clientId: clientB)

        let remaining = manager.subscribers(for: branchId)
        XCTAssertEqual(remaining.count, 2,
                       "Two clients should remain after removing one")
        XCTAssertTrue(remaining.contains(clientA), "Client A must still be subscribed")
        XCTAssertTrue(remaining.contains(clientC), "Client C must still be subscribed")
        XCTAssertNil(manager.subscribedBranch(for: clientB),
                     "Removed client must have no subscription")
    }
}
