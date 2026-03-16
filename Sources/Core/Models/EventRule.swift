import Foundation
import GRDB

// MARK: - Event Rule Model

/// User-defined automation rule: when X happens, do Y.
/// Maps to the `event_trigger_rules` table.
struct EventRule: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "event_trigger_rules"

    var id: String
    var name: String
    var enabled: Bool
    var triggerType: TriggerType
    var triggerConfig: String        // JSON
    var actionType: ActionType
    var actionConfig: String         // JSON
    var lastTriggeredAt: Date?
    var triggerCount: Int
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case triggerType = "trigger_type"
        case triggerConfig = "trigger_config"
        case actionType = "action_type"
        case actionConfig = "action_config"
        case lastTriggeredAt = "last_triggered_at"
        case triggerCount = "trigger_count"
        case createdAt = "created_at"
    }

    // MARK: - Trigger Types

    enum TriggerType: String, Codable, DatabaseValueConvertible, CaseIterable {
        case heartbeatSignal = "heartbeat_signal"
        case errorCount = "error_count"
        case buildFailure = "build_failure"
        case sessionComplete = "session_complete"

        var displayName: String {
            switch self {
            case .heartbeatSignal: return "Heartbeat Signal"
            case .errorCount: return "Error Count"
            case .buildFailure: return "Build Failure"
            case .sessionComplete: return "Session Complete"
            }
        }
    }

    // MARK: - Action Types

    enum ActionType: String, Codable, DatabaseValueConvertible, CaseIterable {
        case dispatchAgent = "dispatch_agent"
        case notify = "notify"
        case runCommand = "run_command"

        var displayName: String {
            switch self {
            case .dispatchAgent: return "Dispatch Agent"
            case .notify: return "Notify"
            case .runCommand: return "Run Command"
            }
        }
    }

    // MARK: - Config Accessors

    var triggerConfigDict: [String: String] {
        guard let data = triggerConfig.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    var actionConfigDict: [String: String] {
        guard let data = actionConfig.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    // MARK: - Cooldown

    /// Minimum 30 minutes between triggers for any single rule.
    static let cooldownSeconds: TimeInterval = 1800

    var isOnCooldown: Bool {
        guard let last = lastTriggeredAt else { return false }
        return Date().timeIntervalSince(last) < Self.cooldownSeconds
    }

    // MARK: - Display

    var triggerDescription: String {
        switch triggerType {
        case .heartbeatSignal:
            let signal = triggerConfigDict["signal"] ?? "any"
            return "When \(signal) signal detected"
        case .errorCount:
            let threshold = triggerConfigDict["threshold"] ?? "5"
            return "When \(threshold)+ consecutive errors"
        case .buildFailure:
            let project = triggerConfigDict["project"] ?? "any"
            return "When build fails (\(project))"
        case .sessionComplete:
            let agent = triggerConfigDict["agent"] ?? "any"
            return "When session completes (\(agent))"
        }
    }

    var actionDescription: String {
        switch actionType {
        case .dispatchAgent:
            let agent = actionConfigDict["agent"] ?? "unknown"
            return "Dispatch \(agent)"
        case .notify:
            return "Create attention event"
        case .runCommand:
            let cmd = actionConfigDict["command"] ?? ""
            return "Run: \(cmd.prefix(40))"
        }
    }

    // MARK: - Factory

    init(
        id: String = UUID().uuidString,
        name: String,
        enabled: Bool = true,
        triggerType: TriggerType,
        triggerConfig: String = "{}",
        actionType: ActionType,
        actionConfig: String = "{}",
        lastTriggeredAt: Date? = nil,
        triggerCount: Int = 0,
        createdAt: Date? = Date()
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.triggerType = triggerType
        self.triggerConfig = triggerConfig
        self.actionType = actionType
        self.actionConfig = actionConfig
        self.lastTriggeredAt = lastTriggeredAt
        self.triggerCount = triggerCount
        self.createdAt = createdAt
    }

    // MARK: - Built-in Templates

    static let defaultRules: [EventRule] = [
        EventRule(
            name: "Build failure auto-fix",
            triggerType: .heartbeatSignal,
            triggerConfig: "{\"signal\":\"build_staleness\"}",
            actionType: .dispatchAgent,
            actionConfig: "{\"agent\":\"geordi\",\"prompt_template\":\"The build is failing for {project}. Diagnose and fix the build errors.\"}"
        ),
        EventRule(
            name: "Error loop intervention",
            triggerType: .errorCount,
            triggerConfig: "{\"threshold\":\"5\"}",
            actionType: .dispatchAgent,
            actionConfig: "{\"agent\":\"worf\",\"prompt_template\":\"Session {session_id} has hit {error_count} consecutive errors. Debug the root cause.\"}"
        ),
        EventRule(
            name: "Stale ticket nudge",
            enabled: false,
            triggerType: .heartbeatSignal,
            triggerConfig: "{\"signal\":\"stale_ticket\"}",
            actionType: .notify,
            actionConfig: "{\"message\":\"Stale tickets detected — review ticket board\"}"
        ),
    ]
}
