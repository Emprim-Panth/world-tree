import Foundation

// MARK: - Sandbox Profile

/// Defines macOS sandbox-exec restrictions for isolated branch execution.
/// Uses Apple's sandbox-exec (Seatbelt) profiles for filesystem/network isolation.
struct SandboxProfile {
    let name: String
    let description: String
    let allowNetwork: Bool
    let allowedPaths: [String]
    let deniedPaths: [String]
    let allowSubprocesses: Bool

    // MARK: - Built-in Profiles

    /// Full access — no restrictions (default for trusted branches)
    static let unrestricted = SandboxProfile(
        name: "unrestricted",
        description: "No restrictions — full access to filesystem and network",
        allowNetwork: true,
        allowedPaths: ["/"],
        deniedPaths: [],
        allowSubprocesses: true
    )

    /// Read-only with network — can browse but not modify
    static let readOnly = SandboxProfile(
        name: "read-only",
        description: "Read-only filesystem access, network allowed",
        allowNetwork: true,
        allowedPaths: ["/"],
        deniedPaths: [],
        allowSubprocesses: true
    )

    /// Workspace-only — restricted to project directory
    static func workspace(path: String) -> SandboxProfile {
        SandboxProfile(
            name: "workspace",
            description: "Limited to project directory: \(path)",
            allowNetwork: true,
            allowedPaths: [
                path,
                "/tmp/",
                FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/",
                "/usr/bin/",
                "/bin/",
                "/opt/homebrew/bin/",
            ],
            deniedPaths: [
                FileManager.default.homeDirectoryForCurrentUser.path + "/.ssh/",
                FileManager.default.homeDirectoryForCurrentUser.path + "/.aws/",
                FileManager.default.homeDirectoryForCurrentUser.path + "/.gnupg/",
            ],
            allowSubprocesses: true
        )
    }

    /// Airgapped — no network, limited filesystem
    static func airgapped(path: String) -> SandboxProfile {
        SandboxProfile(
            name: "airgapped",
            description: "No network, workspace-only filesystem",
            allowNetwork: false,
            allowedPaths: [path, "/tmp/"],
            deniedPaths: [],
            allowSubprocesses: false
        )
    }

    // MARK: - Generate Seatbelt Profile

    /// Generate a sandbox-exec compatible profile string.
    func generateSeatbeltProfile() -> String {
        var profile = "(version 1)\n"

        if name == "unrestricted" {
            profile += "(allow default)\n"
            return profile
        }

        profile += "(deny default)\n"
        profile += "(allow process-exec)\n"
        profile += "(allow process-fork)\n"
        profile += "(allow sysctl-read)\n"
        profile += "(allow mach-lookup)\n"

        // Denied paths FIRST — Seatbelt uses first-match
        for path in deniedPaths {
            let expanded = path.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
            profile += "(deny file-read* (subpath \"\(expanded)\"))\n"
            profile += "(deny file-write* (subpath \"\(expanded)\"))\n"
        }

        // File reads and writes — allowed paths only
        for path in allowedPaths {
            profile += "(allow file-read* (subpath \"\(path)\"))\n"
            profile += "(allow file-write* (subpath \"\(path)\"))\n"
        }

        // Allow reading system libraries and frameworks (required for process exec)
        profile += "(allow file-read* (subpath \"/usr/lib\"))\n"
        profile += "(allow file-read* (subpath \"/usr/bin\"))\n"
        profile += "(allow file-read* (subpath \"/bin\"))\n"
        profile += "(allow file-read* (subpath \"/Library/Frameworks\"))\n"
        profile += "(allow file-read* (subpath \"/System\"))\n"

        // Network
        if allowNetwork {
            profile += "(allow network*)\n"
        } else {
            profile += "(deny network*)\n"
        }

        // Subprocesses
        if allowSubprocesses {
            profile += "(allow process-exec*)\n"
        }

        return profile
    }

    /// Write profile to temp file for sandbox-exec usage.
    func writeTempProfile() -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let profileURL = tempDir.appendingPathComponent("canvas-sandbox-\(name)-\(UUID().uuidString).sb")
        do {
            try generateSeatbeltProfile().write(to: profileURL, atomically: true, encoding: .utf8)
            return profileURL
        } catch {
            canvasLog("[SandboxProfile] Failed to write profile: \(error)")
            return nil
        }
    }
}

// MARK: - Sandbox Executor Protocol

/// Protocol for execution environments — allows swapping between local, sandboxed, and VM.
protocol ExecutionEnvironment {
    var name: String { get }
    func execute(command: String, workingDirectory: URL?) async throws -> (stdout: String, stderr: String, exitCode: Int32)
}

/// Local executor — runs directly on the host (current behavior).
struct LocalExecutor: ExecutionEnvironment {
    let name = "local"

    func execute(command: String, workingDirectory: URL?) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", command]
        if let cwd = workingDirectory {
            proc.currentDirectoryURL = cwd
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()

        // Read pipe data BEFORE waiting for exit to avoid pipe buffer deadlock.
        // If the process writes >64KB, it blocks waiting for the reader.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            proc.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
        }

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (stdout, stderr, exitCode)
    }
}

/// Sandboxed executor — wraps commands with sandbox-exec using Process arguments.
struct SandboxedExecutor: ExecutionEnvironment {
    let name = "sandboxed"
    let profile: SandboxProfile

    func execute(command: String, workingDirectory: URL?) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        guard let profileURL = profile.writeTempProfile() else {
            throw SandboxError.profileWriteFailed
        }
        defer { try? FileManager.default.removeItem(at: profileURL) }

        // Use Process arguments array to avoid command injection
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        proc.arguments = ["-f", profileURL.path, "/bin/bash", "-c", command]
        if let cwd = workingDirectory {
            proc.currentDirectoryURL = cwd
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            proc.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
        }

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (stdout, stderr, exitCode)
    }
}

enum SandboxError: LocalizedError {
    case profileWriteFailed

    var errorDescription: String? {
        switch self {
        case .profileWriteFailed:
            return "Failed to write sandbox profile to temporary directory"
        }
    }
}
