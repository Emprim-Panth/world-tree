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
}
