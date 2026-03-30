import Foundation
import GRDB

/// Routes inference tasks to the cheapest capable provider.
/// Rule-based, not ML. Claude is the surgeon — local models handle triage.
@MainActor
final class QualityRouter: ObservableObject {
    static let shared = QualityRouter()

    @Published private(set) var todayStats = RoutingStats()

    private let ollamaBase = "http://localhost:11434"
    private var logDB: OpaquePointer?  // inference_log goes in conversations.db via DatabaseManager

    private init() {}

    // MARK: - Provider Types

    enum Provider: String, CaseIterable {
        case local72B = "qwen2.5:72b"
        case local32B = "qwen2.5-coder:32b"
        case localEmbed = "nomic-embed-text"
        case claudeSonnet = "claude-sonnet-4-6"
        case claudeOpus = "claude-opus-4-6"

        var isLocal: Bool {
            switch self {
            case .local72B, .local32B, .localEmbed: return true
            case .claudeSonnet, .claudeOpus: return false
            }
        }

        var displayName: String {
            switch self {
            case .local72B: return "Local 72B"
            case .local32B: return "Local 32B"
            case .localEmbed: return "Embeddings"
            case .claudeSonnet: return "Claude Sonnet"
            case .claudeOpus: return "Claude Opus"
            }
        }
    }

    enum TaskType: String {
        case fileSummary        // Scout-style file understanding
        case commitExplain      // Diff/commit explanation
        case ticketScan         // Parse TASK-*.md files
        case briefing           // Morning briefing generation
        case driftDetection     // Compare state to PRD goals
        case healthCheck        // System health monitoring
        case brainSearch        // Semantic search over brain
        case codeGeneration     // Writing new code
        case architecture       // Architecture decisions
        case interactive        // Interactive conversation
    }

    struct RoutingDecision {
        let provider: Provider
        let taskType: TaskType
        let reason: String
    }

    struct RoutingStats {
        var localCount: Int = 0
        var claudeCount: Int = 0
        var escalationCount: Int = 0
        var date: String = {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            return df.string(from: Date())
        }()

        var totalCount: Int { localCount + claudeCount }
        var localPercent: Int {
            guard totalCount > 0 else { return 0 }
            return Int(Double(localCount) / Double(totalCount) * 100)
        }
    }

    // MARK: - Routing

    /// Route a task to the appropriate provider.
    func route(_ taskType: TaskType, context: String? = nil) -> RoutingDecision {
        let decision: RoutingDecision

        switch taskType {
        case .fileSummary:
            decision = RoutingDecision(provider: .local32B, taskType: taskType,
                                       reason: "File summaries are advisory — local 32B code model")

        case .commitExplain:
            let isLarge = (context?.count ?? 0) > 5000  // rough: >500 lines
            if isLarge {
                decision = RoutingDecision(provider: .claudeSonnet, taskType: taskType,
                                           reason: "Large diff (>500 lines) — escalating to Claude")
            } else {
                decision = RoutingDecision(provider: .local32B, taskType: taskType,
                                           reason: "Standard diff — local 32B code model")
            }

        case .ticketScan:
            decision = RoutingDecision(provider: .local72B, taskType: taskType,
                                       reason: "Structured extraction — local 72B")

        case .briefing:
            decision = RoutingDecision(provider: .local72B, taskType: taskType,
                                       reason: "Briefing generation — local 72B reasoning")

        case .driftDetection:
            decision = RoutingDecision(provider: .local72B, taskType: taskType,
                                       reason: "Drift analysis — local 72B reasoning")

        case .healthCheck:
            decision = RoutingDecision(provider: .local72B, taskType: taskType,
                                       reason: "Binary health check — always local")

        case .brainSearch:
            decision = RoutingDecision(provider: .localEmbed, taskType: taskType,
                                       reason: "Embedding search — local nomic-embed-text")

        case .codeGeneration:
            decision = RoutingDecision(provider: .claudeSonnet, taskType: taskType,
                                       reason: "Code generation requires Claude quality")

        case .architecture:
            decision = RoutingDecision(provider: .claudeOpus, taskType: taskType,
                                       reason: "Architecture decisions need frontier reasoning")

        case .interactive:
            decision = RoutingDecision(provider: .claudeSonnet, taskType: taskType,
                                       reason: "Interactive sessions use Claude")
        }

        // Track stats
        if decision.provider.isLocal {
            todayStats.localCount += 1
        } else {
            todayStats.claudeCount += 1
        }

        // Reset stats on new day
        let today = {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            return df.string(from: Date())
        }()
        if todayStats.date != today {
            todayStats = RoutingStats()
        }

        logRouting(decision)
        return decision
    }

    /// Check if a local model result should be escalated to Claude.
    func shouldEscalate(confidence: String, taskType: TaskType) -> Bool {
        // Never escalate these
        switch taskType {
        case .fileSummary, .healthCheck, .ticketScan, .brainSearch:
            return false
        default:
            break
        }

        // Escalate on low confidence
        return confidence == "low"
    }

    // MARK: - Local Inference

    /// Run inference on a local Ollama model.
    func localInfer(model: String, prompt: String, systemPrompt: String? = nil) async -> (String, Int)? {
        guard let url = URL(string: "\(ollamaBase)/api/generate") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]
        if let sys = systemPrompt {
            payload["system"] = sys
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? String else { return nil }
            let tokens = json["eval_count"] as? Int ?? 0
            return (response, tokens)
        } catch {
            wtLog("[QualityRouter] Local inference failed: \(error)")
            return nil
        }
    }

    // MARK: - Model Status

    struct ModelStatus {
        let name: String
        let size: String
        let isLoaded: Bool
    }

    /// Check which models are currently loaded in Ollama.
    func loadedModels() async -> [ModelStatus] {
        guard let url = URL(string: "\(ollamaBase)/api/ps") else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return [] }

            return models.map { m in
                ModelStatus(
                    name: m["name"] as? String ?? "unknown",
                    size: formatBytes(m["size"] as? Int64 ?? 0),
                    isLoaded: true
                )
            }
        } catch {
            return []
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes > 1_000_000_000 {
            return String(format: "%.0f GB", Double(bytes) / 1_000_000_000)
        } else if bytes > 1_000_000 {
            return String(format: "%.0f MB", Double(bytes) / 1_000_000)
        }
        return "\(bytes) B"
    }

    // MARK: - Logging

    private func logRouting(_ decision: RoutingDecision) {
        do {
            try DatabaseManager.shared.write { db in
                try db.execute(sql: """
                    INSERT INTO inference_log (task_type, provider, created_at)
                    VALUES (?, ?, datetime('now'))
                """, arguments: [decision.taskType.rawValue, decision.provider.rawValue])
            }
        } catch {
            // Table might not exist yet — silent fail until migration runs
        }
    }

    /// Get today's routing breakdown from the database.
    func refreshStats() {
        let today = {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            return df.string(from: Date())
        }()

        do {
            let rows = try DatabaseManager.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT provider, COUNT(*) as cnt
                    FROM inference_log
                    WHERE date(created_at) = ?
                    GROUP BY provider
                """, arguments: [today])
            }

            var stats = RoutingStats()
            stats.date = today
            for row in rows {
                let provider = row["provider"] as? String ?? ""
                let count = row["cnt"] as? Int ?? 0
                if provider.starts(with: "qwen") || provider.starts(with: "nomic") {
                    stats.localCount += count
                } else {
                    stats.claudeCount += count
                }
            }
            todayStats = stats
        } catch {
            // Table might not exist yet
        }
    }
}
