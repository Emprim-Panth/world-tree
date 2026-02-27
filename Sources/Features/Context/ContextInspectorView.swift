import SwiftUI
import GRDB

// MARK: - Token Estimation Constants

private enum TokenEstimation {
    /// Approximate characters per token for text content (GPT/Claude tokenizers average ~3.5 chars/token)
    static let charsPerToken: Double = 3.5
    /// Estimated token overhead for a tool_use content block (JSON structure + tool name + input schema)
    static let toolUseOverhead: Int = 50
    /// Estimated token cost for an inline base64 image block
    static let imageOverhead: Int = 500
    /// Number of most-recent messages that are always protected from deletion
    static let recentMessageCount: Int = 4
    /// Target percentage of maxTokens after compaction
    static let compactionTargetRatio: Double = 0.6
}

/// Context window inspector and management
struct ContextInspectorView: View {
    @StateObject private var viewModel: ContextInspectorViewModel

    init(sessionId: String) {
        _viewModel = StateObject(wrappedValue: ContextInspectorViewModel(sessionId: sessionId))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Context gauge header
            contextGaugeSection

            Divider()

            // Section list with pinning
            List {
                ForEach(viewModel.sections) { section in
                    ContextSectionRow(
                        section: section,
                        onTogglePin: {
                            viewModel.togglePin(section.id)
                        },
                        onDelete: {
                            viewModel.deleteSection(section.id)
                        }
                    )
                }
            }
            .listStyle(.inset)

            Divider()

            // Controls
            HStack {
                Button("Compact Now") {
                    viewModel.compactNow()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Auto-Compact: \(viewModel.autoCompactEnabled ? "ON" : "OFF")") {
                    viewModel.toggleAutoCompact()
                }
                .buttonStyle(.borderless)
            }
            .padding()
        }
        .frame(minWidth: 400, idealWidth: 500)
        .onAppear {
            viewModel.loadSections()
        }
    }

    private var contextGaugeSection: some View {
        VStack(spacing: 12) {
            // Circular gauge
            ContextGaugeView(
                current: viewModel.currentTokens,
                max: viewModel.maxTokens,
                threshold: viewModel.rotationThreshold
            )

            // Stats
            HStack(spacing: 24) {
                VStack(spacing: 4) {
                    Text("\(viewModel.currentTokens.formatted())")
                        .font(.title2.monospacedDigit().bold())
                    Text("Current")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()
                    .frame(height: 40)

                VStack(spacing: 4) {
                    Text("\(viewModel.pinnedTokens.formatted())")
                        .font(.title2.monospacedDigit().bold())
                        .foregroundColor(.blue)
                    Text("Pinned")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()
                    .frame(height: 40)

                VStack(spacing: 4) {
                    Text("\(viewModel.availableTokens.formatted())")
                        .font(.title2.monospacedDigit().bold())
                        .foregroundColor(.green)
                    Text("Available")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Rotation threshold slider
            VStack(alignment: .leading, spacing: 4) {
                Text("Rotation Threshold: \(Int(viewModel.thresholdPercentage))%")
                    .font(.caption.bold())

                Slider(value: $viewModel.thresholdPercentage, in: 50...95, step: 5)
                    .tint(.orange)

                Text("Context will rotate when reaching \(viewModel.rotationThreshold.formatted()) tokens")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
    }
}

@MainActor
class ContextInspectorViewModel: ObservableObject {
    @Published var sections: [ContextSection] = []
    @Published var currentTokens: Int = 0
    @Published var maxTokens: Int = 200_000
    @Published var thresholdPercentage: Double = 75.0
    @Published var autoCompactEnabled: Bool =
        UserDefaults.standard.object(forKey: "cortana.autoCompactEnabled") as? Bool ?? true

    private let sessionId: String

    /// Decoded source arrays — kept in sync with sections for write-back to canvas_api_state
    private var cachedApiMessages: [APIMessage] = []
    private var cachedSystemBlocks: [SystemBlock] = []
    /// Number of leading sections that represent system blocks (vs. message turns)
    private var systemBlockCount: Int = 0

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    var rotationThreshold: Int {
        Int(Double(maxTokens) * (thresholdPercentage / 100.0))
    }

    var pinnedTokens: Int {
        sections.filter { $0.isPinned }.reduce(0) { $0 + $1.tokenCount }
    }

    var availableTokens: Int {
        max(0, maxTokens - currentTokens)
    }

    func loadSections() {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }

        let decoder = JSONDecoder()

        // Load persisted system blocks and message history from canvas_api_state
        let row = try? dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT system_prompt, api_messages, token_usage, updated_at FROM canvas_api_state WHERE session_id = ? ORDER BY updated_at DESC LIMIT 1",
                arguments: [sessionId]
            )
        }

        var builtSections: [ContextSection] = []
        var totalTokens = 0
        var loadedBlocks: [SystemBlock] = []
        var loadedMessages: [APIMessage] = []

        if let row {
            // System prompt blocks → one section per block
            if let systemStr: String = row["system_prompt"],
               let data = systemStr.data(using: .utf8),
               let blocks = try? decoder.decode([SystemBlock].self, from: data) {
                loadedBlocks = blocks
                for (i, block) in blocks.enumerated() {
                    let title = systemBlockTitle(for: block.text, index: i)
                    let snippet = String(block.text.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                    let tokens = tokenEstimate(for: block.text)
                    totalTokens += tokens
                    builtSections.append(ContextSection(
                        id: UUID(),
                        title: title,
                        content: snippet,
                        tokenCount: tokens,
                        timestamp: Date(timeIntervalSinceNow: -3600),
                        isPinned: block.isPinned,
                        canDelete: false
                    ))
                }
            }

            // Message history — group into user/assistant turns
            if let msgStr: String = row["api_messages"],
               let data = msgStr.data(using: .utf8),
               let messages = try? decoder.decode([APIMessage].self, from: data) {
                loadedMessages = messages
                var turnIndex = 0
                var i = 0
                while i < messages.count {
                    let msg = messages[i]
                    let role = msg.role == "user" ? "You" : LocalAgentIdentity.name
                    let textContent = msg.content.compactMap { block -> String? in
                        if case .text(let t) = block { return t }
                        return nil
                    }.joined(separator: " ")
                    let snippet = String(textContent.prefix(100)).replacingOccurrences(of: "\n", with: " ")
                    let tokens = msg.content.reduce(0) { acc, block in
                        switch block {
                        case .text(let t): return acc + tokenEstimate(for: t)
                        case .toolResult(let tr): return acc + tokenEstimate(for: tr.content)
                        case .toolUse: return acc + TokenEstimation.toolUseOverhead
                        case .image: return acc + TokenEstimation.imageOverhead
                        }
                    }
                    totalTokens += tokens
                    let isRecent = i >= messages.count - TokenEstimation.recentMessageCount
                    builtSections.append(ContextSection(
                        id: UUID(),
                        title: "[\(role)] Turn \(turnIndex + 1)",
                        content: snippet.isEmpty ? "(tool use / image)" : snippet,
                        tokenCount: tokens,
                        timestamp: Date(timeIntervalSinceNow: TimeInterval(-(messages.count - i) * 60)),
                        isPinned: false,
                        canDelete: !isRecent
                    ))
                    turnIndex += 1
                    i += 1
                }
            }

            // Use actual token usage if available
            if let usageStr: String = row["token_usage"],
               let data = usageStr.data(using: .utf8),
               let usage = try? decoder.decode(SessionTokenUsage.self, from: data),
               usage.totalInputTokens > 0 {
                totalTokens = usage.totalInputTokens
            }
        }

        if builtSections.isEmpty {
            // Session hasn't sent through API yet — show placeholder
            builtSections = [ContextSection(
                id: UUID(),
                title: "No API session data",
                content: "Send a message via Anthropic API to populate context inspector",
                tokenCount: 0,
                timestamp: Date(),
                isPinned: false,
                canDelete: false
            )]
        }

        cachedSystemBlocks = loadedBlocks
        cachedApiMessages = loadedMessages
        systemBlockCount = loadedBlocks.count
        sections = builtSections
        currentTokens = totalTokens
    }

    /// Write current cachedApiMessages + cachedSystemBlocks back to canvas_api_state.
    private func persistMutations() {
        let encoder = JSONEncoder()
        do {
            let messagesJSON = String(data: try encoder.encode(cachedApiMessages), encoding: .utf8) ?? "[]"
            let systemJSON = String(data: try encoder.encode(cachedSystemBlocks), encoding: .utf8) ?? "[]"
            try DatabaseManager.shared.write { db in
                try db.execute(
                    sql: """
                        UPDATE canvas_api_state
                        SET api_messages = ?, system_prompt = ?, updated_at = datetime('now')
                        WHERE session_id = ?
                        """,
                    arguments: [messagesJSON, systemJSON, sessionId]
                )
            }
        } catch {
            wtLog("[ContextInspector] Failed to persist mutations: \(error)")
        }
    }

    /// Derive a human-readable title from the content of a system block.
    private func systemBlockTitle(for text: String, index: Int) -> String {
        if text.contains("You are Cortana") || text.contains("First Officer") {
            return "\(LocalAgentIdentity.name) Identity"
        } else if text.contains("CLAUDE.md") || text.contains("Operating Principles") {
            return "CLAUDE.md Instructions"
        } else if text.contains("Active Project:") || text.contains("# Active Project") {
            return "Project Intelligence"
        } else if text.contains("Recent Session Context") || text.contains("cortana-context-restore") {
            return "Session Context"
        } else if text.hasPrefix("<terminal_output>") {
            return "Terminal Output"
        } else if text.hasPrefix("[Relevant knowledge]") {
            return "Knowledge Base"
        } else {
            return "System Block \(index + 1)"
        }
    }

    private func tokenEstimate(for text: String) -> Int {
        max(1, Int(Double(text.count) / TokenEstimation.charsPerToken))
    }

    func togglePin(_ sectionId: UUID) {
        guard let index = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        sections[index].isPinned.toggle()

        // Sync to cached system blocks (message turns don't have a pin mechanism in the API)
        if index < systemBlockCount {
            guard index < cachedSystemBlocks.count else {
                wtLog("[ContextInspector] togglePin: section index \(index) exceeds cachedSystemBlocks count \(cachedSystemBlocks.count) — skipping cache sync")
                return
            }
            if cachedSystemBlocks[index].isPinned {
                cachedSystemBlocks[index].cacheControl = nil
            } else {
                cachedSystemBlocks[index].cacheControl = CacheControl(type: "ephemeral")
            }
            persistMutations()
        }
    }

    func deleteSection(_ sectionId: UUID) {
        guard let index = sections.firstIndex(where: { $0.id == sectionId }),
              sections[index].canDelete else { return }

        let tokenCount = sections[index].tokenCount

        // Remove from cached messages (only message turns can be deleted — system blocks have canDelete: false)
        let messageIndex = index - systemBlockCount
        guard messageIndex >= 0 && messageIndex < cachedApiMessages.count else {
            wtLog("[ContextInspector] deleteSection: computed messageIndex \(messageIndex) out of bounds (sections: \(sections.count), systemBlockCount: \(systemBlockCount), apiMessages: \(cachedApiMessages.count)) — aborting delete to prevent data corruption")
            return
        }

        cachedApiMessages.remove(at: messageIndex)
        sections.remove(at: index)
        currentTokens -= tokenCount
        persistMutations()
    }

    func compactNow() {
        // Remove unpinned sections, oldest first
        let unpinned = sections.filter { !$0.isPinned && $0.canDelete }
            .sorted { $0.timestamp < $1.timestamp }

        var tokensFreed = 0
        let targetTokens = Int(Double(maxTokens) * TokenEstimation.compactionTargetRatio)
        var sectionsToRemoveIds: [UUID] = []

        for section in unpinned {
            if currentTokens - tokensFreed <= targetTokens { break }
            if let idx = sections.firstIndex(where: { $0.id == section.id }) {
                tokensFreed += sections[idx].tokenCount
                sectionsToRemoveIds.append(section.id)
            }
        }

        guard !sectionsToRemoveIds.isEmpty else { return }

        // Collect message indices before removing from sections (indices are still valid)
        var messageIndicesToRemove: [Int] = []
        for id in sectionsToRemoveIds {
            if let idx = sections.firstIndex(where: { $0.id == id }) {
                let msgIdx = idx - systemBlockCount
                if msgIdx >= 0 && msgIdx < cachedApiMessages.count {
                    messageIndicesToRemove.append(msgIdx)
                } else if msgIdx >= 0 {
                    wtLog("[ContextInspector] compactNow: computed msgIdx \(msgIdx) out of bounds (apiMessages: \(cachedApiMessages.count)) — skipping removal for section \(id)")
                }
            }
        }

        sections.removeAll { sectionsToRemoveIds.contains($0.id) }
        currentTokens -= tokensFreed

        for msgIdx in messageIndicesToRemove.sorted().reversed() {
            cachedApiMessages.remove(at: msgIdx)
        }

        persistMutations()
    }

    func toggleAutoCompact() {
        autoCompactEnabled.toggle()
        UserDefaults.standard.set(autoCompactEnabled, forKey: "cortana.autoCompactEnabled")
    }
}

// MARK: - Context Gauge

struct ContextGaugeView: View {
    let current: Int
    let max: Int
    let threshold: Int

    var body: some View {
        Gauge(value: Double(current), in: 0...Double(max)) {
            Text("Context")
        } currentValueLabel: {
            Text("\(Int(percentage))%")
                .font(.system(.title3, design: .rounded).monospacedDigit())
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(gaugeGradient)
        .scaleEffect(1.5)
    }

    private var percentage: Double {
        (Double(current) / Double(max)) * 100
    }

    private var gaugeGradient: LinearGradient {
        if percentage >= 90 {
            return LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)
        } else if percentage >= 75 {
            return LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing)
        } else {
            return LinearGradient(colors: [.green, .blue], startPoint: .leading, endPoint: .trailing)
        }
    }
}

// MARK: - Context Section Row

struct ContextSectionRow: View {
    let section: ContextSection
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Pin button
            Button(action: onTogglePin) {
                Image(systemName: section.isPinned ? "pin.fill" : "pin.slash")
                    .foregroundColor(section.isPinned ? .blue : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help(section.isPinned ? "Unpin section" : "Pin section")

            VStack(alignment: .leading, spacing: 4) {
                Text(section.title)
                    .font(.subheadline.bold())

                Text(section.content)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label("\(section.tokenCount.formatted()) tokens", systemImage: "number")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(section.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if section.canDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Delete section")
            }
        }
        .padding(.vertical, 4)
        .opacity(section.isPinned ? 1.0 : 0.7)
    }
}

// MARK: - Models

struct ContextSection: Identifiable {
    let id: UUID
    var title: String
    var content: String
    var tokenCount: Int
    var timestamp: Date
    var isPinned: Bool
    var canDelete: Bool
}

// MARK: - View Extension

extension View {
    /// Add context inspector sheet
    func contextInspector(sessionId: String, isPresented: Binding<Bool>) -> some View {
        self.sheet(isPresented: isPresented) {
            ContextInspectorView(sessionId: sessionId)
        }
    }
}
