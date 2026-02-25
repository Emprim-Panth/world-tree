import Foundation
import Observation

/// Tracks which branches are actively being processed by an LLM.
/// Lets the sidebar show live state even when the user has navigated away.
@Observable
final class ProcessingRegistry {
    static let shared = ProcessingRegistry()
    private init() {}

    private(set) var activeBranchIds: Set<String> = []

    var anyProcessing: Bool { !activeBranchIds.isEmpty }

    func register(_ branchId: String) {
        activeBranchIds.insert(branchId)
    }

    func deregister(_ branchId: String) {
        activeBranchIds.remove(branchId)
    }

    func isProcessing(_ branchId: String) -> Bool {
        activeBranchIds.contains(branchId)
    }
}
