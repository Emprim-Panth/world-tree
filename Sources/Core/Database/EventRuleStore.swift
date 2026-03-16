import Foundation
import GRDB

// MARK: - Triggered Action

struct TriggeredAction {
    let rule: EventRule
    let action: EventRule.ActionType
    let config: [String: String]
}

// MARK: - Event Rule Store

/// CRUD + matching engine for event trigger rules.
/// Evaluates rules against live signals on every heartbeat cycle.
@MainActor
final class EventRuleStore: ObservableObject {
    static let shared = EventRuleStore()

    @Published private(set) var rules: [EventRule] = []

    /// Global hourly dispatch cap.
    private static let maxDispatchesPerHour = 3
    /// Global daily dispatch cap.
    private static let maxDispatchesPerDay = 15

    /// Tracks dispatch timestamps for rate limiting.
    private var dispatchTimestamps: [Date] = []

    private init() {}

    // MARK: - Load

    func loadRules() {
        do {
            rules = try DatabaseManager.shared.read { db in
                guard try db.tableExists("event_trigger_rules") else { return [] }
                return try EventRule.fetchAll(db, sql: """
                    SELECT * FROM event_trigger_rules ORDER BY created_at ASC
                    """)
            }

            // Seed default rules on first launch
            if rules.isEmpty {
                for rule in EventRule.defaultRules {
                    createRule(rule)
                }
            }
        } catch {
            wtLog("[EventRuleStore] Failed to load rules: \(error)")
        }
    }

    // MARK: - CRUD

    func createRule(_ rule: EventRule) {
        do {
            try DatabaseManager.shared.write { db in
                try rule.insert(db)
            }
            loadRules()
        } catch {
            wtLog("[EventRuleStore] Failed to create rule: \(error)")
        }
    }

    func updateRule(_ rule: EventRule) {
        do {
            try DatabaseManager.shared.write { db in
                try rule.update(db)
            }
            loadRules()
        } catch {
            wtLog("[EventRuleStore] Failed to update rule: \(error)")
        }
    }

    func deleteRule(_ id: String) {
        do {
            _ = try DatabaseManager.shared.write { db in
                try db.execute(sql: "DELETE FROM event_trigger_rules WHERE id = ?", arguments: [id])
            }
            loadRules()
        } catch {
            wtLog("[EventRuleStore] Failed to delete rule: \(error)")
        }
    }

    func toggleRule(_ id: String, enabled: Bool) {
        do {
            try DatabaseManager.shared.write { db in
                try db.execute(
                    sql: "UPDATE event_trigger_rules SET enabled = ? WHERE id = ?",
                    arguments: [enabled, id]
                )
            }
            loadRules()
        } catch {
            wtLog("[EventRuleStore] Failed to toggle rule: \(error)")
        }
    }

    // MARK: - Evaluation Engine

    /// Evaluate all enabled rules against current state.
    /// Called by DispatchSupervisor heartbeat (every 30s).
    func evaluate(
        sessions: [AgentSession],
        attentionEvents: [AttentionEvent]
    ) async -> [TriggeredAction] {
        pruneOldTimestamps()
        var triggered: [TriggeredAction] = []

        for rule in rules where rule.enabled && !rule.isOnCooldown {
            if matchesTrigger(rule: rule, sessions: sessions, events: attentionEvents) {
                // Check rate limits
                guard canDispatch(rule: rule) else {
                    wtLog("[EventRuleStore] Rate limit hit — skipping rule '\(rule.name)'")
                    continue
                }

                triggered.append(TriggeredAction(
                    rule: rule,
                    action: rule.actionType,
                    config: rule.actionConfigDict
                ))

                // Record the trigger
                recordTrigger(ruleId: rule.id)
                if rule.actionType == .dispatchAgent {
                    dispatchTimestamps.append(Date())
                }
            }
        }

        return triggered
    }

    // MARK: - Trigger Matching

    private func matchesTrigger(
        rule: EventRule,
        sessions: [AgentSession],
        events: [AttentionEvent]
    ) -> Bool {
        let config = rule.triggerConfigDict

        switch rule.triggerType {
        case .heartbeatSignal:
            // Match if there's a recent attention event of the specified signal type
            let signal = config["signal"] ?? ""
            return events.contains { $0.type.rawValue == signal && $0.isUnacknowledged }

        case .errorCount:
            let threshold = Int(config["threshold"] ?? "5") ?? 5
            return sessions.contains { $0.consecutiveErrors >= threshold && $0.isActive }

        case .buildFailure:
            let project = config["project"]
            return events.contains { event in
                guard event.type == .errorLoop && event.isUnacknowledged else { return false }
                if let project, project != "any" {
                    // Check if the session's project matches
                    return sessions.contains { $0.id == event.sessionId && $0.project == project }
                }
                return true
            }

        case .sessionComplete:
            let agent = config["agent"]
            return sessions.contains { session in
                guard session.status == .completed else { return false }
                if let agent, agent != "any" {
                    return session.agentName == agent
                }
                return true
            }
        }
    }

    // MARK: - Rate Limiting

    private func canDispatch(rule: EventRule) -> Bool {
        guard rule.actionType == .dispatchAgent else { return true }

        let now = Date()
        let hourAgo = now.addingTimeInterval(-3600)
        let dayAgo = now.addingTimeInterval(-86400)

        let hourlyCount = dispatchTimestamps.filter { $0 > hourAgo }.count
        let dailyCount = dispatchTimestamps.filter { $0 > dayAgo }.count

        return hourlyCount < Self.maxDispatchesPerHour && dailyCount < Self.maxDispatchesPerDay
    }

    private func pruneOldTimestamps() {
        let dayAgo = Date().addingTimeInterval(-86400)
        dispatchTimestamps.removeAll { $0 < dayAgo }
    }

    // MARK: - Record Trigger

    private func recordTrigger(ruleId: String) {
        do {
            try DatabaseManager.shared.write { db in
                try db.execute(sql: """
                    UPDATE event_trigger_rules
                    SET last_triggered_at = datetime('now'),
                        trigger_count = trigger_count + 1
                    WHERE id = ?
                    """, arguments: [ruleId])
            }
            loadRules()
        } catch {
            wtLog("[EventRuleStore] Failed to record trigger: \(error)")
        }
    }
}
