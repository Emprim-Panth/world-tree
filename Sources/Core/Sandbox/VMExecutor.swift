import Foundation

// MARK: - VM Executor (Virtualization.framework Stub)

/// Future implementation: local VMs per branch for true isolation.
/// Uses Apple's Virtualization.framework for macOS-native lightweight VMs.
/// Currently a stub that throws — callers must check `isAvailable` first.
struct VMExecutor: ExecutionEnvironment {
    let name = "vm"
    let branchId: String

    func execute(command: String, workingDirectory: URL?) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        // TODO: Implement Virtualization.framework integration
        // - Create lightweight Linux VM per branch
        // - Mount workspace directory as shared folder
        // - Execute commands inside VM
        // - Capture stdout/stderr via virtio-console
        throw VMExecutorError.notImplemented
    }

    /// Check if Virtualization.framework is available on this system.
    /// Returns false — VM isolation is not yet implemented.
    static var isAvailable: Bool {
        return false
    }
}

enum VMExecutorError: LocalizedError {
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "VM isolation not yet implemented — use LocalExecutor or SandboxedExecutor instead"
        }
    }
}
