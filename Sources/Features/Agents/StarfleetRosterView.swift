import SwiftUI

// MARK: - Starfleet Roster View

/// Full crew roster with specialties, availability status, and invocation controls.
/// Supports one-click compilation and dispatch to specific agents.
struct StarfleetRosterView: View {
    @StateObject private var roster = StarfleetRoster.shared
    @State private var selectedAgent: StarfleetAgent?
    @State private var isShowingDispatchSheet = false
    @State private var compilingAgentId: String?
    @State private var compilationResult: String?
    @State private var showCompilationResult = false
    @State private var filterText = ""
    @State private var showReservesExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            ScrollView {
                VStack(spacing: 12) {
                    coreCrewSection
                    reserveCrewSection
                }
                .padding()
            }
        }
        .sheet(isPresented: $isShowingDispatchSheet) {
            if let agent = selectedAgent {
                StarfleetDispatchSheet(agent: agent)
            }
        }
        .sheet(isPresented: $showCompilationResult) {
            compilationResultSheet
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "person.3.fill")
                .foregroundStyle(.cyan)
            Text("Starfleet Roster")
                .font(.headline)

            Spacer()

            // Agent count
            let available = roster.agents.filter(\.isAvailable).count
            Text("\(available)/\(roster.agents.count) ready")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                roster.loadRoster()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Refresh roster")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            TextField("Filter agents...", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Core Crew

    private var coreCrewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.cyan)
                    .frame(width: 6, height: 6)
                Text("CORE CREW")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            let filtered = filteredAgents(tier: .core)
            if filtered.isEmpty {
                Text("No matching agents")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 12)
            } else {
                ForEach(filtered) { agent in
                    AgentRosterRow(
                        agent: agent,
                        isCompiling: compilingAgentId == agent.id,
                        onCompile: { compileAgent(agent) },
                        onDispatch: { selectForDispatch(agent) }
                    )
                }
            }
        }
    }

    // MARK: - Reserves

    private var reserveCrewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showReservesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.purple)
                        .frame(width: 6, height: 6)
                    Text("RESERVES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: showReservesExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if showReservesExpanded {
                let filtered = filteredAgents(tier: .reserve)
                if filtered.isEmpty {
                    Text("No matching agents")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 12)
                } else {
                    ForEach(filtered) { agent in
                        AgentRosterRow(
                            agent: agent,
                            isCompiling: compilingAgentId == agent.id,
                            onCompile: { compileAgent(agent) },
                            onDispatch: { selectForDispatch(agent) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Compilation Result Sheet

    private var compilationResultSheet: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Agent Compiled")
                    .font(.headline)
                Spacer()
                Button {
                    showCompilationResult = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                Text(compilationResult ?? "No output")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.8))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Done") { showCompilationResult = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 400)
    }

    // MARK: - Helpers

    private func filteredAgents(tier: StarfleetAgent.Tier) -> [StarfleetAgent] {
        let tiered = roster.agents.filter { $0.tier == tier }
        guard !filterText.isEmpty else { return tiered }
        let query = filterText.lowercased()
        return tiered.filter {
            $0.displayName.lowercased().contains(query) ||
            $0.domain.lowercased().contains(query) ||
            $0.triggers.contains(where: { $0.lowercased().contains(query) })
        }
    }

    private func compileAgent(_ agent: StarfleetAgent) {
        compilingAgentId = agent.id
        Task {
            let result = await roster.compile(agentId: agent.id)
            compilingAgentId = nil
            if let result {
                compilationResult = result
                showCompilationResult = true
            }
        }
    }

    private func selectForDispatch(_ agent: StarfleetAgent) {
        selectedAgent = agent
        isShowingDispatchSheet = true
    }
}

// MARK: - Agent Roster Row

private struct AgentRosterRow: View {
    let agent: StarfleetAgent
    let isCompiling: Bool
    let onCompile: () -> Void
    let onDispatch: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Status + icon
            ZStack {
                Circle()
                    .fill(agent.agentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: agent.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(agent.agentColor)
            }

            // Name + domain
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .font(.system(size: 12, weight: .semibold))

                    if !agent.isAvailable {
                        Text("unavailable")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(3)
                    }

                    Text(agent.model)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .cornerRadius(3)
                }

                Text(agent.domain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Trigger tags (first 3)
            HStack(spacing: 3) {
                ForEach(agent.triggers.prefix(3), id: \.self) { trigger in
                    Text(trigger)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .cornerRadius(3)
                }
            }

            // Actions
            HStack(spacing: 6) {
                // Compile button
                Button {
                    onCompile()
                } label: {
                    if isCompiling {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Compile agent identity")
                .disabled(!agent.isAvailable || isCompiling)

                // Dispatch button
                Button {
                    onDispatch()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(agent.isAvailable ? agent.agentColor : .secondary)
                .help("Dispatch task to \(agent.displayName)")
                .disabled(!agent.isAvailable)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(agent.agentColor.opacity(0.03))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(agent.agentColor.opacity(0.1))
        )
    }
}
