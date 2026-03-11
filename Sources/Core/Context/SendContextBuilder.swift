import Foundation

/// Builds enriched context for any caller sending a message to an LLM provider.
///
/// Centralizes the context assembly logic that was previously duplicated across
/// DocumentEditorViewModel, ClaudeBridge.sendDirect(), and WorldTreeServer.
/// Every send path now gets the same quality of context injection:
///
/// 1. ConversationScorer — selects high-value sections from in-session history
/// 2. MemoryService — cross-session recall from conversation_archive + knowledge FTS
/// 3. Checkpoint context — carried forward from rotated sessions
/// 4. Project context — git branch, README, project type
/// 5. Working directory + parent session resolution
@MainActor
enum SendContextBuilder {

    /// Build a fully-enriched ProviderSendContext ready for any provider.
    ///
    /// - Parameters:
    ///   - message: The user's message text
    ///   - sessionId: Current session ID
    ///   - branchId: Current branch ID
    ///   - model: Model override (nil = use default)
    ///   - workingDirectory: Explicit working directory (nil = resolve from project)
    ///   - project: Project name for context filtering
    ///   - checkpointContext: Checkpoint from session rotation (nil if no rotation occurred)
    ///   - sections: In-session conversation sections for scoring (nil = skip scoring)
    ///   - isSessionStale: Whether the session is stale (>15 min gap or first send)
    ///   - attachments: File/image attachments
    /// - Returns: Fully-enriched ProviderSendContext
    static func build(
        message: String,
        sessionId: String,
        branchId: String,
        model: String? = nil,
        workingDirectory: String? = nil,
        project: String? = nil,
        checkpointContext: String? = nil,
        sections: [DocumentSection]? = nil,
        isSessionStale: Bool = true,
        attachments: [Attachment] = []
    ) -> ProviderSendContext {
        // 1. Resolve working directory and project
        let resolvedWorkingDir = workingDirectory ?? resolveWorkingDirectory(nil, project: project)
        let resolvedProject = project ?? URL(fileURLWithPath: resolvedWorkingDir).lastPathComponent

        // 2. Resolve parent session for fork/resume inheritance
        let parentSessionId = resolveParentSessionId(branchId: branchId)
        let isNewSession = !MessageStore.shared.hasMessages(sessionId: sessionId)

        // 3. Score conversation sections (if available)
        let scoredContext = buildScoredContext(
            sections: sections,
            query: message,
            isSessionStale: isSessionStale,
            checkpointContext: checkpointContext
        )

        // 4. Cross-session memory recall
        let memoryBlock = MemoryService.shared.recallForMessage(
            message,
            project: resolvedProject,
            sessionId: sessionId
        )

        // 5. Merge scored context + memory
        let enrichedContext = mergeContext(scored: scoredContext, memory: memoryBlock)

        // 6. Layer on project context for CLI providers
        let projectContext = loadProjectContext(project: resolvedProject, workingDirectory: resolvedWorkingDir)
        let baseContext: String?
        if let enriched = enrichedContext, !projectContext.isEmpty {
            baseContext = "\(projectContext)\n\n\(enriched)"
        } else if !projectContext.isEmpty {
            baseContext = projectContext
        } else {
            baseContext = enrichedContext
        }

        // 7. Guaranteed recent messages — last 20 turns from DB, bypasses scoring.
        //    Ensures cold starts and post-compaction sessions always know the thread.
        let recentMessages = buildRecentMessagesContext(sessionId: sessionId)

        // 8. Gameplan — project north star, always injected when present.
        let gameplan = loadGameplan(project: resolvedProject, workingDirectory: resolvedWorkingDir)

        // 9. Assemble: gameplan first, then recent turns, then scored/memory context.
        var contextParts: [String] = []
        if let gp = gameplan { contextParts.append(gp) }
        if let recent = recentMessages { contextParts.append(recent) }
        if let base = baseContext { contextParts.append(base) }
        let finalContext: String? = contextParts.isEmpty ? nil : contextParts.joined(separator: "\n\n")

        let extendedThinking = UserDefaults.standard.bool(forKey: AppConstants.extendedThinkingEnabledKey)

        var ctx = ProviderSendContext(
            message: message,
            sessionId: sessionId,
            branchId: branchId,
            model: model ?? UserDefaults.standard.string(forKey: AppConstants.defaultModelKey) ?? AppConstants.defaultModel,
            workingDirectory: resolvedWorkingDir,
            project: resolvedProject,
            parentSessionId: parentSessionId,
            isNewSession: isNewSession,
            attachments: attachments,
            recentContext: finalContext,
            extendedThinking: extendedThinking
        )
        ctx.checkpointContext = checkpointContext

        return ctx
    }

    // MARK: - Scored Context

    /// Build context from conversation sections using ConversationScorer,
    /// or format a rotation checkpoint if one exists.
    private static func buildScoredContext(
        sections: [DocumentSection]?,
        query: String,
        isSessionStale: Bool,
        checkpointContext: String?
    ) -> String? {
        // Rotation checkpoint takes priority — it's the most accurate summary
        if let checkpoint = checkpointContext {
            return "CONTEXT CHECKPOINT (conversation was compacted — use this as your memory of earlier work):\n"
                + checkpoint
                + "\nEND CHECKPOINT"
        }

        guard let sections, !sections.isEmpty else { return nil }

        let maxAdditional = isSessionStale ? 20 : 4
        let selected = ConversationScorer.select(
            sections: sections,
            query: query,
            mandatoryCount: 4,
            maxAdditional: maxAdditional
        )

        guard !selected.isEmpty else { return nil }

        let lines = selected.map { section -> String in
            let role: String
            switch section.author {
            case .user: role = "You"
            case .assistant: role = LocalAgentIdentity.name
            case .system: role = "System"
            }
            let text = String(section.content.characters.prefix(1000))
            return "[\(role)]: \(text)"
        }

        if isSessionStale {
            wtLog("[ContextBuilder] Stale session — injecting \(selected.count) turns")
        }

        return "CONVERSATION CONTEXT (recent history — use if session memory is unclear):\n"
            + lines.joined(separator: "\n\n")
            + "\nEND CONTEXT"
    }

    // MARK: - Merge

    /// Merge scored context and cross-session memory into a single block.
    private static func mergeContext(scored: String?, memory: String) -> String? {
        if let scored, !memory.isEmpty {
            return "\(scored)\n\n\(memory)"
        } else if !memory.isEmpty {
            return memory
        } else {
            return scored
        }
    }

    // MARK: - Project Context

    /// Load project context from cache (no async git calls).
    private static func loadProjectContext(project: String?, workingDirectory: String?) -> String {
        guard let cwd = workingDirectory else { return "" }
        let cache = ProjectCache()

        let cached: CachedProject?
        if let byPath = try? cache.get(path: cwd) {
            cached = byPath
        } else if let name = project, let byName = try? cache.getByName(name) {
            cached = byName
        } else {
            cached = nil
        }

        guard let project = cached else { return "" }

        var output = "# Project Context: \(project.name)\n"
        output += "**Type:** \(project.type.displayName)\n"
        output += "**Path:** `\(project.path)`\n"
        if let branch = project.gitBranch {
            output += "**Git Branch:** `\(branch)`"
            if project.gitDirty { output += " (uncommitted changes)" }
            output += "\n"
        }
        if let readme = project.readme, !readme.isEmpty {
            output += "\n## README\n\(readme)\n"
        }
        return output
    }

    // MARK: - Recent Messages (guaranteed injection)

    /// Always include the last N messages from the current session, regardless of
    /// ConversationScorer output. This guarantees that cold starts and post-compaction
    /// sessions never lose track of what was just discussed.
    private static func buildRecentMessagesContext(sessionId: String, limit: Int = 20) -> String? {
        let messages: [Message]
        do {
            messages = try MessageStore.shared.getMessages(sessionId: sessionId, limit: limit)
        } catch {
            wtLog("[SendContextBuilder] buildRecentMessagesContext failed for session \(sessionId): \(error)")
            return nil
        }
        guard !messages.isEmpty else { return nil }

        let lines = messages.compactMap { msg -> String? in
            let prefix: String
            switch msg.role {
            case .user:      prefix = "[You]"
            case .assistant: prefix = "[\(LocalAgentIdentity.name)]"
            case .system:    return nil
            }
            return "\(prefix): \(String(msg.content.prefix(800)))"
        }

        guard !lines.isEmpty else { return nil }

        return "RECENT CONVERSATION (last \(lines.count) turns — always present):\n"
            + lines.joined(separator: "\n\n")
            + "\nEND RECENT"
    }

    // MARK: - Gameplan

    /// Load the active project gameplan from ~/.cortana/gameplans/{project}/GAMEPLAN.md.
    /// The gameplan is the agreed north star — injected on every send, including after
    /// compaction, so the direction is never lost regardless of session state.
    private static func loadGameplan(project: String?, workingDirectory: String?) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var candidates: [String] = []
        if let p = project, !p.isEmpty {
            candidates.append("\(home)/.cortana/gameplans/\(p.lowercased())/GAMEPLAN.md")
            candidates.append("\(home)/.cortana/gameplans/\(p)/GAMEPLAN.md")
        }
        if let wd = workingDirectory {
            let name = URL(fileURLWithPath: wd).lastPathComponent
            candidates.append("\(home)/.cortana/gameplans/\(name.lowercased())/GAMEPLAN.md")
        }

        for path in candidates {
            if let content = try? String(contentsOfFile: path, encoding: .utf8), !content.isEmpty {
                wtLog("[SendContextBuilder] Injecting gameplan from \(path)")
                return "PROJECT GAMEPLAN (north star — all work stays aligned with this):\n"
                    + content
                    + "\nEND GAMEPLAN"
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Look up the parent branch's session ID for context inheritance.
    private static func resolveParentSessionId(branchId: String) -> String? {
        do {
            guard let branch = try TreeStore.shared.getBranch(branchId),
                  let parentBranchId = branch.parentBranchId else {
                return nil
            }
            guard let parentBranch = try TreeStore.shared.getBranch(parentBranchId) else {
                return nil
            }
            return parentBranch.sessionId
        } catch {
            wtLog("[SendContextBuilder] resolveParentSessionId failed for branch \(branchId): \(error)")
            return nil
        }
    }
}
