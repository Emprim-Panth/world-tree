import SwiftUI

// MARK: - Event Rules Sheet

/// Settings UI for creating, editing, enabling/disabling, and deleting event trigger rules.
/// Accessible from Command Center header.
struct EventRulesSheet: View {
    @ObservedObject var store: EventRuleStore = .shared
    @State private var editingRule: EventRule?
    @State private var isCreatingNew = false
    @State private var ruleToDelete: EventRule?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.rules.isEmpty {
                emptyState
            } else {
                ruleList
            }
        }
        .frame(width: 600, height: 500)
        .background(.ultraThinMaterial)
        .sheet(item: $editingRule) { rule in
            EventRuleEditorSheet(rule: rule) { updated in
                store.updateRule(updated)
            }
        }
        .sheet(isPresented: $isCreatingNew) {
            EventRuleEditorSheet(rule: nil) { newRule in
                store.createRule(newRule)
            }
        }
        .alert("Delete Rule?", isPresented: .init(
            get: { ruleToDelete != nil },
            set: { if !$0 { ruleToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { ruleToDelete = nil }
            Button("Delete", role: .destructive) {
                if let rule = ruleToDelete {
                    store.deleteRule(rule.id)
                    ruleToDelete = nil
                }
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .onAppear { store.loadRules() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Event Rules")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("Automated responses to agent events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isCreatingNew = true
            } label: {
                Label("New Rule", systemImage: "plus")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .controlSize(.small)

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bolt.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No event rules configured")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Rules automate responses to agent events — build failures, error loops, session completions.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Create First Rule") { isCreatingNew = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Rule List

    private var ruleList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(store.rules) { rule in
                    ruleRow(rule)
                }
            }
            .padding()
        }
    }

    private func ruleRow(_ rule: EventRule) -> some View {
        HStack(spacing: 10) {
            // Enable/disable toggle
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { store.toggleRule(rule.id, enabled: $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(rule.enabled ? .primary : .secondary)

                    if rule.isOnCooldown {
                        Text("cooldown")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Text(rule.triggerDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(rule.actionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if let lastTriggered = rule.lastTriggeredAt {
                        Text("Last: \(relativeTime(lastTriggered))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Never triggered")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    if rule.triggerCount > 0 {
                        Text("\(rule.triggerCount) time\(rule.triggerCount == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            Button { editingRule = rule } label: {
                Image(systemName: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button { ruleToDelete = rule } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.6))
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(rule.enabled ? Color.accentColor.opacity(0.15) : Color.clear, lineWidth: 1)
        )
        .opacity(rule.enabled ? 1.0 : 0.7)
    }

    // MARK: - Helpers

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

// MARK: - Rule Editor Sheet

struct EventRuleEditorSheet: View {
    let rule: EventRule?
    let onSave: (EventRule) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var triggerType: EventRule.TriggerType = .errorCount
    @State private var actionType: EventRule.ActionType = .notify
    @State private var enabled: Bool = true

    // Trigger config
    @State private var signalCategory: String = "build_staleness"
    @State private var errorThreshold: String = "5"
    @State private var projectFilter: String = "any"
    @State private var agentFilter: String = "any"

    // Action config
    @State private var dispatchAgent: String = "geordi"
    @State private var promptTemplate: String = ""
    @State private var notifyMessage: String = ""
    @State private var runCommand: String = ""
    @State private var workingDirectory: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(rule == nil ? "New Rule" : "Edit Rule")
                    .font(.title3).fontWeight(.bold)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            Form {
                Section("General") {
                    TextField("Name", text: $name)
                    Toggle("Enabled", isOn: $enabled)
                }

                Section("Trigger") {
                    Picker("When", selection: $triggerType) {
                        ForEach(EventRule.TriggerType.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }

                    switch triggerType {
                    case .heartbeatSignal:
                        TextField("Signal category", text: $signalCategory)
                    case .errorCount:
                        TextField("Consecutive error threshold", text: $errorThreshold)
                    case .buildFailure:
                        TextField("Project (or \"any\")", text: $projectFilter)
                    case .sessionComplete:
                        TextField("Agent name (or \"any\")", text: $agentFilter)
                    }
                }

                Section("Action") {
                    Picker("Then", selection: $actionType) {
                        ForEach(EventRule.ActionType.allCases, id: \.self) { a in
                            Text(a.displayName).tag(a)
                        }
                    }

                    switch actionType {
                    case .dispatchAgent:
                        TextField("Agent name", text: $dispatchAgent)
                        TextField("Prompt template", text: $promptTemplate, axis: .vertical)
                            .lineLimit(3...6)
                    case .notify:
                        TextField("Notification message", text: $notifyMessage)
                    case .runCommand:
                        TextField("Command", text: $runCommand)
                        TextField("Working directory", text: $workingDirectory)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 500)
        .onAppear { loadFromRule() }
    }

    private func loadFromRule() {
        guard let rule else { return }
        name = rule.name
        triggerType = rule.triggerType
        actionType = rule.actionType
        enabled = rule.enabled

        let tc = rule.triggerConfigDict
        switch rule.triggerType {
        case .heartbeatSignal: signalCategory = tc["signal"] ?? "build_staleness"
        case .errorCount: errorThreshold = tc["threshold"] ?? "5"
        case .buildFailure: projectFilter = tc["project"] ?? "any"
        case .sessionComplete: agentFilter = tc["agent"] ?? "any"
        }

        let ac = rule.actionConfigDict
        switch rule.actionType {
        case .dispatchAgent:
            dispatchAgent = ac["agent"] ?? "geordi"
            promptTemplate = ac["prompt_template"] ?? ""
        case .notify:
            notifyMessage = ac["message"] ?? ""
        case .runCommand:
            runCommand = ac["command"] ?? ""
            workingDirectory = ac["working_directory"] ?? ""
        }
    }

    private func save() {
        let triggerConfig: String
        switch triggerType {
        case .heartbeatSignal: triggerConfig = "{\"signal\":\"\(signalCategory)\"}"
        case .errorCount: triggerConfig = "{\"threshold\":\"\(errorThreshold)\"}"
        case .buildFailure: triggerConfig = "{\"project\":\"\(projectFilter)\"}"
        case .sessionComplete: triggerConfig = "{\"agent\":\"\(agentFilter)\"}"
        }

        let actionConfig: String
        switch actionType {
        case .dispatchAgent:
            let escaped = promptTemplate.replacingOccurrences(of: "\"", with: "\\\"")
            actionConfig = "{\"agent\":\"\(dispatchAgent)\",\"prompt_template\":\"\(escaped)\"}"
        case .notify:
            let escaped = notifyMessage.replacingOccurrences(of: "\"", with: "\\\"")
            actionConfig = "{\"message\":\"\(escaped)\"}"
        case .runCommand:
            actionConfig = "{\"command\":\"\(runCommand)\",\"working_directory\":\"\(workingDirectory)\"}"
        }

        let updated = EventRule(
            id: rule?.id ?? UUID().uuidString,
            name: name,
            enabled: enabled,
            triggerType: triggerType,
            triggerConfig: triggerConfig,
            actionType: actionType,
            actionConfig: actionConfig,
            lastTriggeredAt: rule?.lastTriggeredAt,
            triggerCount: rule?.triggerCount ?? 0,
            createdAt: rule?.createdAt ?? Date()
        )

        onSave(updated)
        dismiss()
    }
}
