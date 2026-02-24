import Foundation

// MARK: - VM Executor (Virtualization.framework Stub)

/// Future implementation: local VMs per branch for true isolation.
/// Uses Apple's Virtualization.framework for macOS-native lightweight VMs.
/// Currently a stub that falls back to local execution.
struct VMExecutor: ExecutionEnvironment {
    let name = "vm"
    let branchId: String

    func execute(command: String, workingDirectory: URL?) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        // TODO: Implement Virtualization.framework integration
        // - Create lightweight Linux VM per branch
        // - Mount workspace directory as shared folder
        // - Execute commands inside VM
        // - Capture stdout/stderr via virtio-console
        //
        // For now, fall back to local execution with a warning
        canvasLog("[VMExecutor] VM isolation not yet implemented, falling back to local execution")
        let local = LocalExecutor()
        return try await local.execute(command: command, workingDirectory: workingDirectory)
    }

    /// Check if Virtualization.framework is available on this system.
    /// Returns false because execute() always falls back to LocalExecutor — VM isolation is not yet implemented.
    static var isAvailable: Bool {
        return false
    }
}
