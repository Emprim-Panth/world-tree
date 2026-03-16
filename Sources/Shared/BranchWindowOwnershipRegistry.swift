import Foundation

@MainActor
final class BranchWindowOwnershipRegistry {
    static let shared = BranchWindowOwnershipRegistry()

    private struct Claim {
        let ownerId: UUID
        let claimedAt: Date
    }

    private var claimsByBranchId: [String: [Claim]] = [:]

    private init() {}

    func claim(branchId: String, ownerId: UUID) {
        var claims = claimsByBranchId[branchId, default: []]
        claims.removeAll { $0.ownerId == ownerId }
        claims.append(Claim(ownerId: ownerId, claimedAt: Date()))
        claimsByBranchId[branchId] = claims
    }

    func release(branchId: String, ownerId: UUID) {
        guard var claims = claimsByBranchId[branchId] else { return }
        claims.removeAll { $0.ownerId == ownerId }
        if claims.isEmpty {
            claimsByBranchId.removeValue(forKey: branchId)
        } else {
            claimsByBranchId[branchId] = claims
        }
    }

    func owner(for branchId: String) -> UUID? {
        claimsByBranchId[branchId]?
            .max(by: { $0.claimedAt < $1.claimedAt })?
            .ownerId
    }

    func isOwner(branchId: String, ownerId: UUID) -> Bool {
        owner(for: branchId) == ownerId
    }

    func hasOwner(for branchId: String) -> Bool {
        owner(for: branchId) != nil
    }

    func reset() {
        claimsByBranchId.removeAll()
    }
}
