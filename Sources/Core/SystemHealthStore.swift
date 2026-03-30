import Foundation

/// Checks health of local infrastructure: Ollama, ContextServer, Compass DB, brain-index.
@MainActor
final class SystemHealthStore: ObservableObject {
    static let shared = SystemHealthStore()

    @Published private(set) var checks: [HealthCheck] = []
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var isChecking = false
    @Published private(set) var overallStatus: OverallStatus = .unknown

    enum OverallStatus: String {
        case healthy, degraded, down, unknown

        var icon: String {
            switch self {
            case .healthy: return "checkmark.circle.fill"
            case .degraded: return "exclamationmark.triangle.fill"
            case .down: return "xmark.circle.fill"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    struct HealthCheck: Identifiable {
        let id = UUID()
        let name: String
        let status: Status
        let detail: String
        let latencyMs: Int?

        enum Status: String {
            case ok, warning, error, unknown
        }
    }

    private init() {}

    // MARK: - Run All Checks

    func runAllChecks() async {
        guard !isChecking else { return }
        isChecking = true
        defer {
            isChecking = false
            lastCheckDate = Date()
            updateOverallStatus()
        }

        var results: [HealthCheck] = []

        async let ollama = checkOllama()
        async let context = checkContextServer()
        async let compass = checkCompassDB()
        async let brain = checkBrainIndex()

        results.append(await ollama)
        results.append(await context)
        results.append(await compass)
        results.append(await brain)

        checks = results
    }

    private func updateOverallStatus() {
        if checks.isEmpty {
            overallStatus = .unknown
        } else if checks.allSatisfy({ $0.status == .ok }) {
            overallStatus = .healthy
        } else if checks.contains(where: { $0.status == .error }) {
            overallStatus = .down
        } else {
            overallStatus = .degraded
        }
    }

    // MARK: - Individual Checks

    private func checkOllama() async -> HealthCheck {
        guard let url = URL(string: "http://localhost:11434/api/tags") else {
            return HealthCheck(name: "Ollama", status: .error, detail: "Invalid URL", latencyMs: nil)
        }

        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return HealthCheck(name: "Ollama", status: .error, detail: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)", latencyMs: ms)
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                return HealthCheck(name: "Ollama", status: .ok, detail: "\(models.count) models loaded", latencyMs: ms)
            }
            return HealthCheck(name: "Ollama", status: .warning, detail: "Running but no models", latencyMs: ms)
        } catch {
            return HealthCheck(name: "Ollama", status: .error, detail: "Not reachable", latencyMs: nil)
        }
    }

    private func checkContextServer() async -> HealthCheck {
        guard let url = URL(string: "http://127.0.0.1:4863/intelligence/status") else {
            return HealthCheck(name: "ContextServer", status: .error, detail: "Invalid URL", latencyMs: nil)
        }

        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return HealthCheck(name: "ContextServer", status: .error, detail: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)", latencyMs: ms)
            }
            return HealthCheck(name: "ContextServer", status: .ok, detail: "Port 4863 responding", latencyMs: ms)
        } catch {
            return HealthCheck(name: "ContextServer", status: .error, detail: "Not reachable", latencyMs: nil)
        }
    }

    private func checkCompassDB() async -> HealthCheck {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.cortana/compass.db"

        guard FileManager.default.fileExists(atPath: path) else {
            return HealthCheck(name: "Compass DB", status: .error, detail: "File missing", latencyMs: nil)
        }

        let projects = CompassStore.shared.states.count
        if projects > 0 {
            return HealthCheck(name: "Compass DB", status: .ok, detail: "\(projects) projects tracked", latencyMs: nil)
        }
        return HealthCheck(name: "Compass DB", status: .warning, detail: "No projects loaded", latencyMs: nil)
    }

    private func checkBrainIndex() async -> HealthCheck {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.cortana/brain-index.db"

        guard FileManager.default.fileExists(atPath: path) else {
            return HealthCheck(name: "Brain Index", status: .warning, detail: "Not yet indexed", latencyMs: nil)
        }

        let chunks = BrainIndexer.shared.chunkCount
        if chunks > 0 {
            return HealthCheck(name: "Brain Index", status: .ok, detail: "\(chunks) chunks indexed", latencyMs: nil)
        }
        return HealthCheck(name: "Brain Index", status: .warning, detail: "Index empty", latencyMs: nil)
    }
}
