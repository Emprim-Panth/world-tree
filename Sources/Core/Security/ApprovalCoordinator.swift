import SwiftUI

// MARK: - Approval Request

struct ApprovalRequest: Identifiable {
    let id = UUID()
    let assessment: ToolGuard.Assessment
    let command: String
    fileprivate let continuation: CheckedContinuation<Bool, Never>
}

// MARK: - Approval Coordinator

/// @MainActor singleton that bridges ToolExecutor (actor) to the SwiftUI approval sheet.
/// ToolExecutor calls requestApproval() and suspends; the sheet resolves it.
@MainActor
final class ApprovalCoordinator: ObservableObject {
    static let shared = ApprovalCoordinator()

    @Published var pendingRequest: ApprovalRequest?

    private init() {}

    /// Called from ToolExecutor. Checks PermissionStore first — suspends to show
    /// the sheet only if the pattern hasn't been permanently approved.
    func requestApproval(assessment: ToolGuard.Assessment, command: String) async -> Bool {
        if PermissionStore.shared.isApproved(reason: assessment.reason) {
            canvasLog("[ApprovalCoordinator] Auto-approved (remembered): \(assessment.reason)")
            return true
        }

        return await withCheckedContinuation { continuation in
            pendingRequest = ApprovalRequest(
                assessment: assessment,
                command: command,
                continuation: continuation
            )
        }
    }

    /// Called by the approval sheet when the user makes a decision.
    func resolve(approved: Bool, remember: Bool) {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        if approved && remember {
            PermissionStore.shared.approve(reason: request.assessment.reason)
            canvasLog("[ApprovalCoordinator] Permanently approved: \(request.assessment.reason)")
        }
        request.continuation.resume(returning: approved)
    }
}
