import SwiftUI

// MARK: - Approval Request

struct ApprovalRequest: Identifiable {
    let id = UUID()
    let assessment: ToolGuard.Assessment
    let command: String
    fileprivate let continuation: CheckedContinuation<Bool, Never>
}

// MARK: - File Diff Request

/// Suspend-until-reviewed request for a file write/edit operation.
struct FileDiffRequest: Identifiable {
    let id = UUID()
    let filePath: String
    let oldContent: String
    let newContent: String
    fileprivate let continuation: CheckedContinuation<Bool, Never>
}

// MARK: - Approval Coordinator

/// @MainActor singleton that bridges ToolExecutor (actor) to the SwiftUI approval sheet.
/// ToolExecutor calls requestApproval() and suspends; the sheet resolves it.
@MainActor
final class ApprovalCoordinator: ObservableObject {
    static let shared = ApprovalCoordinator()

    @Published var pendingRequest: ApprovalRequest?
    @Published var pendingFileDiff: FileDiffRequest?

    private init() {}

    /// Called from ToolExecutor. Checks PermissionStore first — suspends to show
    /// the sheet only if the pattern hasn't been permanently approved.
    func requestApproval(assessment: ToolGuard.Assessment, command: String) async -> Bool {
        if PermissionStore.shared.isApproved(reason: assessment.reason) {
            wtLog("[ApprovalCoordinator] Auto-approved (remembered): \(assessment.reason)")
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
            wtLog("[ApprovalCoordinator] Permanently approved: \(request.assessment.reason)")
        }
        request.continuation.resume(returning: approved)
    }

    // MARK: - File Diff Review

    /// Present a diff review sheet and suspend until the user accepts or rejects.
    /// Only called when Settings → "Review File Writes" is enabled.
    func requestFileDiffApproval(filePath: String, oldContent: String, newContent: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            pendingFileDiff = FileDiffRequest(
                filePath: filePath,
                oldContent: oldContent,
                newContent: newContent,
                continuation: continuation
            )
        }
    }

    /// Called by the diff review sheet.
    func resolveFileDiff(approved: Bool) {
        guard let request = pendingFileDiff else { return }
        pendingFileDiff = nil
        wtLog("[ApprovalCoordinator] File diff \(approved ? "accepted" : "rejected"): \(request.filePath)")
        request.continuation.resume(returning: approved)
    }
}
