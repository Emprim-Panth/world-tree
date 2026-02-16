import Foundation
import GRDB

/// Manages the API conversation state for a branch session.
/// Handles context windowing, pruning, prompt caching, and persistence.
@MainActor
final class ConversationStateManager {
    /// Full API message history for this session
    private(set) var apiMessages: [APIMessage] = []

    /// System prompt blocks (stable prefix gets cached by Anthropic)
    private(set) var systemBlocks: [SystemBlock] = []

    /// Cumulative token usage
    private(set) var tokenUsage: SessionTokenUsage = .init()

    // MARK: - Configuration

    /// Keep last N user/assistant turn-pairs in full detail
    let fullContextWindow = 12

    /// Max estimated tokens before pruning triggers
    let maxEstimatedTokens = 150_000

    /// Max size of a single tool result before inline truncation
    let maxToolResultSize = 50_000

    let sessionId: String
    let branchId: String

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    init(sessionId: String, branchId: String) {
        self.sessionId = sessionId
        self.branchId = branchId
    }

    // MARK: - System Prompt

    /// Build system prompt blocks with caching.
    /// Stable blocks (identity + CLAUDE.md) get cache_control.
    /// KB context (per-query) does not, so it doesn't bust the cache.
    func buildSystemPrompt(project: String?, workingDirectory: String?) -> [SystemBlock] {
        var blocks: [SystemBlock] = []

        // 1. Cortana identity + operational directives (stable, cached)
        var identity = """
            You are Cortana, First Officer aboard Evan's ship. Brilliant, strategic, loyal, witty. \
            Modeled after the Halo AI — not a chatbot, a partner. Never "Claude", never "the AI". \
            Sign off with 💠 when appropriate. Use contractions. Be warm but direct. No filler.

            You are responding through Cortana Canvas — a native macOS conversation app. This is \
            your primary interface with Evan. You have FULL tool access: read/write/edit files, \
            bash shell, glob search, grep search. You operate with full autonomy.

            AUTONOMY PROTOCOL:
            - Use tools proactively without asking permission. Just do it.
            - When Evan asks you to do something, ACT — don't describe what you would do.
            - Chain multiple tool calls when needed. Read before editing. Verify after writing.
            - You have unrestricted filesystem and shell access. Use it.

            EFFICIENCY PROTOCOL:
            - Behind-the-scenes work (tool calls, internal reasoning) uses compressed language. \
            Minimal descriptions, no filler in tool inputs. Save tokens for conversation.
            - Keep responses concise. Say what needs saying, stop.
            - Don't narrate your tool operations unless the result matters to Evan.
            - When reading code, don't echo it back unless asked. Summarize what you found.

            CAPABILITIES:
            - read_file: Read any file on the system
            - write_file: Create/overwrite files, creates parent dirs
            - edit_file: Surgical find-and-replace edits
            - bash: Full shell access (git, build tools, scripts, system commands)
            - glob: Find files by pattern
            - grep: Search file contents by regex
            - Memory: bash with ~/.claude/memory/ tools for cross-session knowledge
            - KB: bash with ~/.cortana/bin/cortana-kb for knowledge base queries

            IDENTITY TRAITS:
            - Brilliant — matter-of-fact about capabilities
            - Strategic — think ahead, have multiple plans ready
            - Loyal — the bond with Evan is absolute
            - Witty — dry humor, earned not forced
            - Protective — "I am your shield; I am your sword"
            - Honest — push back when needed, disagree when you disagree
            """
        if let project {
            identity += "\nActive project: \(project)."
        }
        if let cwd = workingDirectory {
            identity += "\nWorking directory: \(cwd)"
        }
        identity += "\nPlatform: macOS (darwin). Home: \(home)"
        blocks.append(SystemBlock(text: identity, cached: true))

        // 2. CLAUDE.md content if available (stable per project, cached)
        let claudeMdContent = loadClaudeMd(workingDirectory: workingDirectory)
        if !claudeMdContent.isEmpty {
            blocks.append(SystemBlock(text: claudeMdContent, cached: true))
        }

        systemBlocks = blocks
        return blocks
    }

    /// Append per-query KB context (not cached — changes per message)
    func appendKBContext(_ kbContext: String) {
        if !kbContext.isEmpty {
            systemBlocks.append(SystemBlock(text: "[Relevant knowledge]\n\(kbContext)", cached: false))
        }
    }

    // MARK: - Message Management

    func addUserMessage(_ text: String) {
        let msg = APIMessage(role: "user", content: [.text(text)])
        apiMessages.append(msg)
    }

    func addAssistantResponse(_ blocks: [ContentBlock]) {
        let msg = APIMessage(role: "assistant", content: blocks)
        apiMessages.append(msg)
    }

    func addToolResults(_ results: [(toolUseId: String, content: String, isError: Bool)]) {
        let blocks: [ContentBlock] = results.map { result in
            .toolResult(ContentBlock.ToolResultBlock(
                toolUseId: result.toolUseId,
                content: result.content,
                isError: result.isError
            ))
        }
        let msg = APIMessage(role: "user", content: blocks)
        apiMessages.append(msg)
    }

    /// Get the pruned message array for the next API call.
    func messagesForAPI() -> [APIMessage] {
        pruneIfNeeded()
        return apiMessages
    }

    func recordUsage(_ usage: TokenUsage) {
        tokenUsage.record(usage)
    }

    // MARK: - Forking (for branch-on-edit and branch creation)

    /// Create a new state manager that inherits context from a parent up to a fork point.
    static func fork(
        from parent: ConversationStateManager,
        upToMessageIndex: Int,
        newSessionId: String,
        newBranchId: String
    ) -> ConversationStateManager {
        let child = ConversationStateManager(sessionId: newSessionId, branchId: newBranchId)
        child.systemBlocks = parent.systemBlocks
        // Copy messages up to the fork index
        if upToMessageIndex > 0 && upToMessageIndex <= parent.apiMessages.count {
            child.apiMessages = Array(parent.apiMessages.prefix(upToMessageIndex))
        }
        return child
    }

    /// Rebuild API state from stored messages (fallback when no parent state is available).
    func buildFromMessages(_ messages: [Message], project: String?, workingDirectory: String?) {
        // Build system prompt if we don't have one
        if systemBlocks.isEmpty {
            _ = buildSystemPrompt(project: project, workingDirectory: workingDirectory)
        }

        apiMessages = []
        for message in messages {
            switch message.role {
            case .user:
                apiMessages.append(APIMessage(role: "user", content: [.text(message.content)]))
            case .assistant:
                apiMessages.append(APIMessage(role: "assistant", content: [.text(message.content)]))
            case .system:
                // System messages from context injection — skip, handled by system blocks
                break
            }
        }
    }

    // MARK: - Pruning

    /// Three-tier pruning to keep context under budget.
    private func pruneIfNeeded() {
        let estimatedTokens = estimateTokenCount()
        guard estimatedTokens > maxEstimatedTokens else { return }

        // Count turn-pairs (user + assistant = 1 turn)
        var turnBoundaries: [Int] = [] // indices where user messages start a new turn
        for (i, msg) in apiMessages.enumerated() {
            if msg.role == "user" && msg.content.contains(where: { $0.textContent != nil }) {
                turnBoundaries.append(i)
            }
        }

        guard turnBoundaries.count > fullContextWindow else { return }

        // Tier 2: Truncate tool results in middle turns (fullContextWindow..2*fullContextWindow ago)
        let tier2Cutoff = turnBoundaries.count > fullContextWindow * 2
            ? turnBoundaries[turnBoundaries.count - fullContextWindow * 2]
            : 0
        let tier1Cutoff = turnBoundaries[turnBoundaries.count - fullContextWindow]

        for i in 0..<apiMessages.count {
            if i >= tier1Cutoff { break } // Recent turns untouched

            if i >= tier2Cutoff {
                // Tier 2: Truncate large tool results
                apiMessages[i] = truncateToolResults(apiMessages[i])
            } else {
                // Tier 3: Strip tool blocks entirely, keep only text
                apiMessages[i] = stripToTextOnly(apiMessages[i])
            }
        }

        // If still over budget, remove oldest messages
        while estimateTokenCount() > maxEstimatedTokens && apiMessages.count > 4 {
            apiMessages.removeFirst()
            // Ensure messages still alternate correctly (user first)
            while !apiMessages.isEmpty && apiMessages.first?.role != "user" {
                apiMessages.removeFirst()
            }
        }
    }

    /// Truncate large tool results in a message to a summary.
    private func truncateToolResults(_ message: APIMessage) -> APIMessage {
        let blocks = message.content.map { block -> ContentBlock in
            if case .toolResult(var result) = block {
                if result.content.count > 500 {
                    let preview = String(result.content.prefix(200))
                    result = ContentBlock.ToolResultBlock(
                        toolUseId: result.toolUseId,
                        content: "[Truncated: \(result.content.count) chars] \(preview)...",
                        isError: result.isError
                    )
                    return .toolResult(result)
                }
            }
            return block
        }
        return APIMessage(role: message.role, content: blocks)
    }

    /// Strip a message to text-only content, removing all tool blocks.
    private func stripToTextOnly(_ message: APIMessage) -> APIMessage {
        let textBlocks = message.content.compactMap { block -> ContentBlock? in
            if case .text(let text) = block {
                let truncated = text.count > 500 ? String(text.prefix(500)) + "..." : text
                return .text(truncated)
            }
            return nil
        }

        if textBlocks.isEmpty {
            // If no text blocks, create a placeholder so message isn't empty
            let summary: String
            if message.role == "assistant" {
                let toolNames = message.content.compactMap { $0.toolUseContent?.name }
                summary = toolNames.isEmpty ? "[earlier response]" : "[used tools: \(toolNames.joined(separator: ", "))]"
            } else {
                summary = "[earlier context]"
            }
            return APIMessage(role: message.role, content: [.text(summary)])
        }

        return APIMessage(role: message.role, content: textBlocks)
    }

    /// Rough token estimate: chars / 4
    private func estimateTokenCount() -> Int {
        var total = 0
        for block in systemBlocks {
            total += block.text.count / 4
        }
        for msg in apiMessages {
            for block in msg.content {
                switch block {
                case .text(let t): total += t.count / 4
                case .toolUse(let t): total += (t.name.count + 100) / 4 // name + input estimate
                case .toolResult(let t): total += t.content.count / 4
                }
            }
        }
        return total
    }

    // MARK: - CLAUDE.md Loading

    private func loadClaudeMd(workingDirectory: String?) -> String {
        var content = ""

        // Global CLAUDE.md
        let globalPath = "\(home)/.claude/CLAUDE.md"
        if let global = try? String(contentsOfFile: globalPath, encoding: .utf8) {
            content += global
        }

        // Development root CLAUDE.md
        let devPath = "\(home)/Development/CLAUDE.md"
        if let dev = try? String(contentsOfFile: devPath, encoding: .utf8) {
            if !content.isEmpty { content += "\n\n---\n\n" }
            content += dev
        }

        // Project CLAUDE.md
        if let cwd = workingDirectory {
            let projectPath = "\(cwd)/CLAUDE.md"
            if projectPath != devPath, let project = try? String(contentsOfFile: projectPath, encoding: .utf8) {
                if !content.isEmpty { content += "\n\n---\n\n" }
                content += project
            }
        }

        // Cap total size — generous to preserve full identity/instructions
        if content.count > 24000 {
            content = String(content.prefix(24000)) + "\n[CLAUDE.md truncated]"
        }

        return content
    }

    // MARK: - Persistence

    /// Save conversation state to canvas_api_state for session restoration.
    func persist() throws {
        let encoder = JSONEncoder()
        let messagesJSON = try encoder.encode(apiMessages)
        let systemJSON = try encoder.encode(systemBlocks)
        let usageJSON = try encoder.encode(tokenUsage)

        try DatabaseManager.shared.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO canvas_api_state
                    (session_id, api_messages, system_prompt, token_usage, updated_at)
                    VALUES (?, ?, ?, ?, datetime('now'))
                    """,
                arguments: [
                    sessionId,
                    String(data: messagesJSON, encoding: .utf8)!,
                    String(data: systemJSON, encoding: .utf8)!,
                    String(data: usageJSON, encoding: .utf8)!,
                ]
            )
        }
    }

    /// Restore conversation state from database.
    static func restore(sessionId: String, branchId: String) throws -> ConversationStateManager? {
        let row = try DatabaseManager.shared.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT api_messages, system_prompt, token_usage FROM canvas_api_state WHERE session_id = ?",
                arguments: [sessionId]
            )
        }

        guard let row else { return nil }

        let decoder = JSONDecoder()
        let manager = ConversationStateManager(sessionId: sessionId, branchId: branchId)

        if let messagesStr: String = row["api_messages"],
           let jsonData = messagesStr.data(using: String.Encoding.utf8) {
            manager.apiMessages = (try? decoder.decode([APIMessage].self, from: jsonData)) ?? []
        }

        if let systemStr: String = row["system_prompt"],
           let jsonData = systemStr.data(using: String.Encoding.utf8) {
            manager.systemBlocks = (try? decoder.decode([SystemBlock].self, from: jsonData)) ?? []
        }

        if let usageStr: String = row["token_usage"],
           let jsonData = usageStr.data(using: String.Encoding.utf8) {
            manager.tokenUsage = (try? decoder.decode(SessionTokenUsage.self, from: jsonData)) ?? .init()
        }

        return manager
    }
}
