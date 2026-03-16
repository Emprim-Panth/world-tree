import XCTest
@testable import WorldTree

@MainActor
final class BranchWindowOwnershipRegistryTests: XCTestCase {
    override func tearDown() async throws {
        BranchWindowOwnershipRegistry.shared.reset()
        try await super.tearDown()
    }

    func testLatestClaimWinsOwnership() {
        let branchId = "branch-\(UUID().uuidString)"
        let firstOwner = UUID()
        let secondOwner = UUID()

        BranchWindowOwnershipRegistry.shared.claim(branchId: branchId, ownerId: firstOwner)
        BranchWindowOwnershipRegistry.shared.claim(branchId: branchId, ownerId: secondOwner)

        XCTAssertFalse(
            BranchWindowOwnershipRegistry.shared.isOwner(branchId: branchId, ownerId: firstOwner)
        )
        XCTAssertTrue(
            BranchWindowOwnershipRegistry.shared.isOwner(branchId: branchId, ownerId: secondOwner)
        )
    }

    func testReleasingOwnerPromotesPreviousClaimant() {
        let branchId = "branch-\(UUID().uuidString)"
        let firstOwner = UUID()
        let secondOwner = UUID()

        BranchWindowOwnershipRegistry.shared.claim(branchId: branchId, ownerId: firstOwner)
        BranchWindowOwnershipRegistry.shared.claim(branchId: branchId, ownerId: secondOwner)
        BranchWindowOwnershipRegistry.shared.release(branchId: branchId, ownerId: secondOwner)

        XCTAssertTrue(
            BranchWindowOwnershipRegistry.shared.isOwner(branchId: branchId, ownerId: firstOwner)
        )
    }

    func testReclaimingMovesExistingOwnerToFront() {
        let branchId = "branch-\(UUID().uuidString)"
        let firstOwner = UUID()
        let secondOwner = UUID()

        BranchWindowOwnershipRegistry.shared.claim(branchId: branchId, ownerId: firstOwner)
        BranchWindowOwnershipRegistry.shared.claim(branchId: branchId, ownerId: secondOwner)
        BranchWindowOwnershipRegistry.shared.claim(branchId: branchId, ownerId: firstOwner)

        XCTAssertTrue(
            BranchWindowOwnershipRegistry.shared.isOwner(branchId: branchId, ownerId: firstOwner)
        )
    }
}
