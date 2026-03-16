import SwiftUI

struct CortanaControlView: View {
    @State private var claudeMCP = MCPConfigManager.shared
    @State private var codexMCP = CodexMCPConfigManager.shared
    @StateObject private var pluginServer = PluginServer.shared
    @StateObject private var roster = StarfleetRoster.shared
    @StateObject private var providerManager = ProviderManager.shared
    @StateObject private var claudeAuth = ClaudeCodeAuthManager.shared
    @AppStorage(AppConstants.codexMCPSyncEnabledKey) private var codexMCPSyncEnabled = true
    @AppStorage(AppConstants.cortanaAutoRoutingEnabledKey) private var cortanaAutoRoutingEnabled = false
    @AppStorage(AppConstants.cortanaCrossCheckEnabledKey) private var cortanaCrossCheckEnabled = true
    @State private var previewTarget: CortanaPromptPreviewTarget = .claudeCode
    @State private var workflowScenario: CortanaWorkflowScenario = .coding

    private var rows: [CortanaControlRow] {
        CortanaControlMatrix.rows(
            claudeServerCount: claudeMCP.servers.count,
            codexServerCount: codexMCP.servers.count,
            codexWorldTreeRegistered: codexMCP.worldTreeRegistered,
            pluginServerRunning: pluginServer.isRunning
        )
    }

    private var workflowRoute: CortanaWorkflowRoute {
        providerManager.routePreview(message: workflowScenario.prompt)
    }

    var body: some View {
        Form {
            Section("Control Matrix") {
                Text("Cortana owns the identity and context spine across providers. Claude still has the stronger session lane; Codex now mirrors the MCP registry and can mount World Tree's local MCP server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        matrixHeader("Control")
                        matrixHeader("Claude Code")
                        matrixHeader("Anthropic API")
                        matrixHeader("Codex CLI")
                    }

                    ForEach(rows) { row in
                        GridRow(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title)
                                    .font(.callout.weight(.medium))
                                Text(row.note)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            matrixBadge(row.claudeCode)
                            matrixBadge(row.anthropicAPI)
                            matrixBadge(row.codexCLI)
                        }
                    }
                }
            }

            Section("Codex MCP Sync") {
                Toggle("Mirror Claude MCP servers into Codex", isOn: $codexMCPSyncEnabled)
                    .disabled(!codexMCP.isInstalled)
                    .onChange(of: codexMCPSyncEnabled) { _, enabled in
                        guard enabled else { return }
                        codexMCP.syncFromClaude(includeWorldTree: pluginServer.isRunning)
                    }

                if codexMCP.isInstalled {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(syncStatusColor)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(syncStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    infoRow("Claude MCP", value: "~/.claude/settings.json")
                    infoRow("Codex MCP", value: CodexMCPConfigManager.configPath)
                    infoRow("World Tree MCP", value: CodexMCPConfigManager.worldTreeMCPURL)

                    if !codexMCP.sharedServerNamesWithClaude.isEmpty {
                        infoRow(
                            "Shared",
                            value: codexMCP.sharedServerNamesWithClaude.joined(separator: ", ")
                        )
                    }

                    if !codexMCP.missingServerNamesFromCodex.isEmpty {
                        infoRow(
                            "Missing in Codex",
                            value: codexMCP.missingServerNamesFromCodex.joined(separator: ", ")
                        )
                    }

                    HStack {
                        Button("Sync Now") {
                            codexMCP.syncFromClaude(includeWorldTree: pluginServer.isRunning)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Reload Status") {
                            claudeMCP.reload()
                            codexMCP.reload()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        if codexMCP.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                } else {
                    Label("Codex CLI not found on this Mac", systemImage: "xmark.circle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Section("Claude Recovery") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(claudeAuthStatusColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(claudeAuth.status.statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let authMethod = claudeAuth.status.authMethod, !authMethod.isEmpty {
                    infoRow("Auth Method", value: authMethod)
                }

                if let apiProvider = claudeAuth.status.apiProvider, !apiProvider.isEmpty {
                    infoRow("Provider", value: apiProvider)
                }

                if providerManager.provider(withId: "anthropic-api") != nil {
                    Label(
                        "Anthropic API fallback is ready for Claude-family work if Claude Code is offline.",
                        systemImage: "arrow.trianglehead.branch"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        "Claude API fallback is not configured yet. Add an Anthropic API key to keep Claude available 24/7.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                HStack {
                    Button("Start Claude Login") {
                        claudeAuth.startLogin()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(claudeAuth.status.state == .cliMissing || claudeAuth.isLaunchingLogin)

                    Button("Refresh Status") {
                        claudeAuth.refresh()
                    }
                    .buttonStyle(.bordered)
                    .disabled(claudeAuth.isRefreshing)

                    Spacer()

                    if claudeAuth.isRefreshing || claudeAuth.isLaunchingLogin {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let error = claudeAuth.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Workflow Router") {
                Toggle("Cortana chooses the primary model", isOn: $cortanaAutoRoutingEnabled)

                Toggle("Suggest a reviewer for complex work", isOn: $cortanaCrossCheckEnabled)
                    .disabled(!cortanaAutoRoutingEnabled)

                Text("Codex handles implementation-heavy repo work. Sonnet is the balanced Claude lane. Haiku handles quick/light requests. Opus takes architecture, review, and high-stakes reasoning. Reviewer mode here is a routing hint. Automatic second-pass review only runs in workflows that explicitly ask for a QA chain or challenge pass.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Preview", selection: $workflowScenario) {
                    ForEach(CortanaWorkflowScenario.allCases) { scenario in
                        Text(scenario.title).tag(scenario)
                    }
                }
                .pickerStyle(.segmented)

                infoRow("Prompt", value: workflowScenario.prompt)

                LabeledContent("Primary") {
                    matrixBadge(badge(for: workflowRoute.primaryModelId, level: .full))
                }

                if let reviewer = workflowRoute.reviewerModelId {
                    LabeledContent("Reviewer") {
                        matrixBadge(badge(for: reviewer, level: .partial))
                    }
                }

                LabeledContent("Reason") {
                    Text(workflowRoute.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Prompt Injection") {
                Picker("Preview", selection: $previewTarget) {
                    ForEach(CortanaPromptPreviewTarget.allCases) { target in
                        Text(target.rawValue).tag(target)
                    }
                }
                .pickerStyle(.segmented)

                ScrollView {
                    Text(CortanaControlMatrix.promptPreview(for: previewTarget))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 180, maxHeight: 260)
            }

            Section("Starfleet") {
                let availableAgents = roster.agents.filter(\.isAvailable).count

                HStack(spacing: 6) {
                    Image(systemName: "person.3.fill")
                        .foregroundStyle(.cyan)
                    Text(roster.isLoading
                         ? "Loading crew roster..."
                         : "\(availableAgents)/\(roster.agents.count) crew ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                infoRow("Roster", value: "~/.cortana/starfleet/config.yaml")
                infoRow("Compiler", value: "~/.cortana/bin/cortana-compile")

                Text("Crew dispatch is an app-side lane owned by Cortana. Starfleet now uses the same workflow planner as Command Center, so Auto routing, QA-chain presets, and model selection policy stay aligned across Claude and Codex.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            claudeMCP.reload()
            codexMCP.reload()
            claudeAuth.refresh()
            await providerManager.refreshHealth()
            if roster.agents.isEmpty {
                roster.loadRoster()
            }
        }
    }

    private var syncStatusColor: Color {
        if codexMCP.lastError != nil {
            return .red
        }
        if codexMCP.worldTreeRegistered && codexMCP.missingServerNamesFromCodex.isEmpty {
            return .green
        }
        return .yellow
    }

    private var syncStatusText: String {
        if let error = codexMCP.lastError {
            return error
        }
        if codexMCP.worldTreeRegistered && codexMCP.missingServerNamesFromCodex.isEmpty {
            return "Codex is aligned with the current Claude MCP set."
        }
        if !pluginServer.isRunning {
            return "Plugin server is off, so World Tree is not mounted into Codex."
        }
        return "Codex is available, but some Claude MCP servers are still missing."
    }

    private var claudeAuthStatusColor: Color {
        switch claudeAuth.status.state {
        case .loggedIn:
            return .green
        case .loggedOut:
            return .yellow
        case .cliMissing, .unknown:
            return .red
        }
    }

    private func matrixHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func matrixBadge(_ badge: CortanaControlBadge) -> some View {
        Text(badge.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(badgeBackground(badge.level))
            .foregroundStyle(badgeForeground(badge.level))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func badgeBackground(_ level: CortanaControlLevel) -> Color {
        switch level {
        case .full: return .green.opacity(0.14)
        case .partial: return .yellow.opacity(0.18)
        case .gap: return .red.opacity(0.12)
        case .neutral: return .secondary.opacity(0.12)
        }
    }

    private func badgeForeground(_ level: CortanaControlLevel) -> Color {
        switch level {
        case .full: return .green
        case .partial: return .orange
        case .gap: return .red
        case .neutral: return .secondary
        }
    }

    private func infoRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private func badge(for modelId: String, level: CortanaControlLevel) -> CortanaControlBadge {
        CortanaControlBadge(label: ModelCatalog.label(for: modelId), level: level)
    }
}

private enum CortanaWorkflowScenario: String, CaseIterable, Identifiable {
    case quick = "Quick"
    case coding = "Build"
    case review = "Review"

    var id: String { rawValue }

    var title: String { rawValue }

    var prompt: String {
        switch self {
        case .quick:
            return "Summarize the current branch and rename it if the title is weak."
        case .coding:
            return "Implement the failing GraphStore fix, run the tests, and patch the repo."
        case .review:
            return "Review the workflow architecture and call out the tradeoffs, risks, and missing checks."
        }
    }
}
