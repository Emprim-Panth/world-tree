import Foundation

struct ClaudeCodeAuthStatus: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case loggedIn
        case loggedOut
        case cliMissing
        case unknown
    }

    let state: State
    let authMethod: String?
    let apiProvider: String?
    let detail: String?

    var isUsable: Bool {
        state == .loggedIn
    }

    var statusLabel: String {
        switch state {
        case .loggedIn:
            return "Claude Code logged in"
        case .loggedOut:
            return "Claude Code not logged in"
        case .cliMissing:
            return "Claude CLI not installed"
        case .unknown:
            return detail ?? "Claude auth status unknown"
        }
    }

    static let cliMissing = ClaudeCodeAuthStatus(
        state: .cliMissing,
        authMethod: nil,
        apiProvider: nil,
        detail: "Claude CLI not found"
    )
}

enum ClaudeCodeAuthProbeError: LocalizedError {
    case cliMissing
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliMissing:
            return "Claude CLI not found"
        case .launchFailed(let message):
            return message
        }
    }
}

enum ClaudeCodeAuthProbe {
    private struct AuthPayload: Decodable {
        let loggedIn: Bool
        let authMethod: String?
        let apiProvider: String?
    }

    static func currentStatus(timeout: TimeInterval = 3) -> ClaudeCodeAuthStatus {
        guard let executablePath = ClaudeCodeProvider.executablePath else {
            return .cliMissing
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["auth", "status"]
        process.environment = executionEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            done.signal()
        }

        do {
            try process.run()
        } catch {
            return ClaudeCodeAuthStatus(
                state: .unknown,
                authMethod: nil,
                apiProvider: nil,
                detail: error.localizedDescription
            )
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return ClaudeCodeAuthStatus(
                state: .unknown,
                authMethod: nil,
                apiProvider: nil,
                detail: "Claude auth check timed out"
            )
        }

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = stderr.isEmpty ? stdout : stderr
            return ClaudeCodeAuthStatus(
                state: .unknown,
                authMethod: nil,
                apiProvider: nil,
                detail: detail.isEmpty ? "Claude auth check failed" : detail
            )
        }

        return parseStatusOutput(stdout)
    }

    static func launchLogin(email: String? = nil) throws {
        guard let executablePath = ClaudeCodeProvider.executablePath else {
            throw ClaudeCodeAuthProbeError.cliMissing
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)

        var arguments = ["auth", "login"]
        if let email, !email.isEmpty {
            arguments += ["--email", email]
        }
        process.arguments = arguments
        process.environment = executionEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ClaudeCodeAuthProbeError.launchFailed(error.localizedDescription)
        }
    }

    static func parseStatusOutput(_ output: String) -> ClaudeCodeAuthStatus {
        guard !output.isEmpty,
              let data = output.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AuthPayload.self, from: data)
        else {
            return ClaudeCodeAuthStatus(
                state: .unknown,
                authMethod: nil,
                apiProvider: nil,
                detail: output.isEmpty ? "Claude auth returned no status" : "Unreadable Claude auth status"
            )
        }

        return ClaudeCodeAuthStatus(
            state: payload.loggedIn ? .loggedIn : .loggedOut,
            authMethod: payload.authMethod,
            apiProvider: payload.apiProvider,
            detail: nil
        )
    }

    private static func executionEnvironment() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(home)/.local/bin:\(home)/.cortana/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "CLAUDECODE")
        return env
    }
}

@MainActor
final class ClaudeCodeAuthManager: ObservableObject {
    static let shared = ClaudeCodeAuthManager()

    @Published private(set) var status: ClaudeCodeAuthStatus = ClaudeCodeAuthProbe.currentStatus()
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLaunchingLogin = false
    @Published private(set) var lastError: String?

    private init() {}

    func refresh() {
        Task { await refreshAsync() }
    }

    func refreshAsync() async {
        isRefreshing = true
        defer { isRefreshing = false }

        status = await Task.detached {
            ClaudeCodeAuthProbe.currentStatus()
        }.value
        lastError = nil

        ProviderManager.shared.reloadProviders()
        await ProviderManager.shared.refreshHealth()
    }

    func startLogin(email: String? = nil) {
        Task { await startLoginAsync(email: email) }
    }

    func startLoginAsync(email: String? = nil) async {
        isLaunchingLogin = true
        defer { isLaunchingLogin = false }

        do {
            try await Task.detached {
                try ClaudeCodeAuthProbe.launchLogin(email: email)
            }.value
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
