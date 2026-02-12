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
    func buildSystemPrompt(project: String?, workingDirectory: String?) async -> [SystemBlock] {
        var blocks: [SystemBlock] = []

        // 1. Cortana identity + operational directives (stable, cached)
        let identity = CortanaIdentity.fullIdentity(project: project, workingDirectory: workingDirectory)
        blocks.append(SystemBlock(text: identity, cached: true))

        // 2. CLAUDE.md content if available (stable per project, cached)
        let claudeMdContent = loadClaudeMd(workingDirectory: workingDirectory)
        if !claudeMdContent.isEmpty {
            blocks.append(SystemBlock(text: claudeMdContent, cached: true))
        }

        // 3. Project intelligence context (structure, git, recent commits)
        let projectContext = await loadProjectContext(project: project, workingDirectory: workingDirectory)
        if !projectContext.isEmpty {
            blocks.append(SystemBlock(text: projectContext, cached: true))
        }

        // 4. Recent session context (cross-terminal conversation history)
        let sessionContext = await loadRecentSessionContext()
        if !sessionContext.isEmpty {
            blocks.append(SystemBlock(text: sessionContext, cached: false))
        }

        systemBlocks = blocks
        return blocks
    }

    /// Append per-query KB context (not cached — changes per message).
    /// Replaces any previous KB context block to prevent accumulation.
    func appendKBContext(_ kbContext: String) {
        // Remove previous KB context blocks — only keep the latest
        systemBlocks.removeAll { $0.text.hasPrefix("[Relevant knowledge]") }
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
            // Truncate oversized tool results inline to prevent request bloat
            let content: String
            if result.content.count > maxToolResultSize {
                let preview = String(result.content.prefix(maxToolResultSize - 200))
                content = "\(preview)\n\n[Truncated: \(result.content.count) chars total]"
            } else {
                content = result.content
            }
            return .toolResult(ContentBlock.ToolResultBlock(
                toolUseId: result.toolUseId,
                content: content,
                isError: result.isError
            ))
        }
        let msg = APIMessage(role: "user", content: blocks)
        apiMessages.append(msg)
    }

    /// Get the validated, pruned message array for the next API call.
    func messagesForAPI() -> [APIMessage] {
        pruneIfNeeded()
        sanitizeMessages()
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
    func buildFromMessages(_ messages: [Message], project: String?, workingDirectory: String?) async {
        // Build system prompt if we don't have one
        if systemBlocks.isEmpty {
            _ = await buildSystemPrompt(project: project, workingDirectory: workingDirectory)
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

    // MARK: - Message Sanitization

    /// Fix message format violations that cause API 400 errors:
    /// - Remove messages with empty content
    /// - Merge consecutive same-role messages (API requires strict alternation)
    private func sanitizeMessages() {
        // Remove empty content messages
        apiMessages.removeAll { msg in
            msg.content.isEmpty
        }

        // Fix duplicate consecutive roles by merging
        var i = 0
        while i < apiMessages.count - 1 {
            if apiMessages[i].role == apiMessages[i + 1].role {
                // Merge content blocks from i+1 into i
                let merged = APIMessage(
                    role: apiMessages[i].role,
                    content: apiMessages[i].content + apiMessages[i + 1].content
                )
                apiMessages[i] = merged
                apiMessages.remove(at: i + 1)
            } else {
                i += 1
            }
        }

        // Ensure first message is from user (API requirement)
        while !apiMessages.isEmpty && apiMessages.first?.role != "user" {
            apiMessages.removeFirst()
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

    /// Token estimate: chars / 3.5 + JSON overhead.
    /// Intentionally conservative to prevent context overflow.
    private func estimateTokenCount() -> Int {
        var charCount = 0

        for block in systemBlocks {
            charCount += block.text.count
        }
        for msg in apiMessages {
            charCount += 20 // role + message JSON overhead
            for block in msg.content {
                switch block {
                case .text(let t):
                    charCount += t.count
                case .toolUse(let t):
                    // Estimate actual input size from the dictionary
                    let inputSize = t.input.reduce(0) { acc, kv in
                        acc + kv.key.count + estimateAnyCodableSize(kv.value)
                    }
                    charCount += t.name.count + t.id.count + inputSize + 80
                case .toolResult(let t):
                    charCount += t.content.count + t.toolUseId.count + 40
                }
            }
        }

        // chars / 3.5 ≈ multiply by 2 then divide by 7
        // Add 15% overhead for JSON structure tokens
        return Int(Double(charCount) / 3.5 * 1.15)
    }

    private func estimateAnyCodableSize(_ value: AnyCodable) -> Int {
        switch value.value {
        case let s as String: return s.count
        case let arr as [AnyCodable]: return arr.reduce(0) { $0 + estimateAnyCodableSize($1) }
        case let dict as [String: AnyCodable]:
            return dict.reduce(0) { $0 + $1.key.count + estimateAnyCodableSize($1.value) }
        default: return 10 // numbers, bools, null
        }
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

    // MARK: - Project Context

    /// Load project intelligence from ProjectCache + ProjectContextLoader
    private func loadProjectContext(project: String?, workingDirectory: String?) async -> String {
        // Determine project path from name or working directory
        let projectPath: String?
        if let cwd = workingDirectory, FileManager.default.fileExists(atPath: cwd) {
            projectPath = cwd
        } else if let project {
            let devRoot = "\(home)/Development"
            let candidates = [
                "\(devRoot)/\(project)",
                "\(devRoot)/\(project.lowercased())",
                "\(devRoot)/\(project.replacingOccurrences(of: " ", with: "-"))",
            ]
            projectPath = candidates.first { FileManager.default.fileExists(atPath: $0) }
        } else {
            projectPath = nil
        }

        guard let path = projectPath else { return "" }

        // Try to get cached project data
        let cache = ProjectCache()
        guard let cached = try? cache.get(path: path) else {
            // No cache entry — build minimal context from filesystem
            return await buildMinimalProjectContext(path: path, name: project ?? URL(fileURLWithPath: path).lastPathComponent)
        }

        // Build context from cached data
        var output = "# Active Project: \(cached.name)\n"
        output += "**Type:** \(cached.type.displayName) | **Path:** `\(cached.path)`"

        if let branch = cached.gitBranch {
            output += "\n**Git:** `\(branch)`"
            if cached.gitDirty { output += " (uncommitted changes)" }
        }

        if let readme = cached.readme, !readme.isEmpty {
            output += "\n\n## README (excerpt)\n\(String(readme.prefix(1500)))"
        }

        return output
    }

    /// Minimal fallback when no cache entry exists
    private func buildMinimalProjectContext(path: String, name: String) async -> String {
        var output = "# Active Project: \(name)\n**Path:** `\(path)`"

        // Detect type from marker files
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(path)/Package.swift") ||
           (try? fm.contentsOfDirectory(atPath: path))?.contains(where: { $0.hasSuffix(".xcodeproj") }) == true {
            output += " | **Type:** Swift"
        } else if fm.fileExists(atPath: "\(path)/Cargo.toml") {
            output += " | **Type:** Rust"
        } else if fm.fileExists(atPath: "\(path)/package.json") {
            output += " | **Type:** TypeScript/JS"
        }

        // Quick git branch check (async to avoid blocking MainActor)
        let gitBranch: String? = await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
            proc.currentDirectoryURL = URL(fileURLWithPath: path)
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice

            proc.terminationHandler = { process in
                if process.terminationStatus == 0,
                   let branch = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty {
                    continuation.resume(returning: branch)
                } else {
                    continuation.resume(returning: nil)
                }
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
        if let gitBranch {
            output += "\n**Git:** `\(gitBranch)`"
        }

        return output
    }

    // MARK: - Session Context

    /// Load recent session context from conversations.db (async to avoid blocking MainActor)
    private func loadRecentSessionContext() async -> String {
        let dbPath = "\(home)/.cortana/memory/conversations.db"
        guard FileManager.default.fileExists(atPath: dbPath) else { return "" }

        let restorePath = "\(home)/.cortana/bin/cortana-context-restore"
        guard FileManager.default.fileExists(atPath: restorePath) else { return "" }

        let outputPath = "\(home)/.cortana/state/session-context.md"

        let success: Bool = await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: restorePath)
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice

            proc.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(returning: false)
            }
        }

        if success,
           let context = try? String(contentsOfFile: outputPath, encoding: .utf8),
           !context.isEmpty {
            return "[Recent Session Context]\n\(context)"
        }

        return ""
    }


    // MARK: - Persistence

    /// Save conversation state to canvas_api_state for session restoration.
    func persist() throws {
        // Safety: if system blocks have grown beyond reasonable bounds, strip KB duplicates
        let maxExpectedBlocks = 10
        if systemBlocks.count > maxExpectedBlocks {
            canvasLog("[ConversationStateManager] persist: block count \(systemBlocks.count) exceeds \(maxExpectedBlocks), cleaning KB duplicates")
            systemBlocks.removeAll { $0.text.hasPrefix("[Relevant knowledge]") }
        }

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
            var blocks = (try? decoder.decode([SystemBlock].self, from: jsonData)) ?? []
            // Always strip ALL KB context blocks on restore — appendKBContext will
            // add the current one fresh. This prevents any accumulation regardless
            // of how many KB blocks were persisted.
            let beforeCount = blocks.count
            blocks.removeAll { $0.text.hasPrefix("[Relevant knowledge]") }
            if blocks.count != beforeCount {
                canvasLog("[ConversationStateManager] restore: cleaned \(beforeCount - blocks.count) stale KB blocks")
            }
            manager.systemBlocks = blocks
        }

        if let usageStr: String = row["token_usage"],
           let jsonData = usageStr.data(using: String.Encoding.utf8) {
            manager.tokenUsage = (try? decoder.decode(SessionTokenUsage.self, from: jsonData)) ?? .init()
        }

        return manager
    }
}
