import Foundation

/// Builds context injection when forking a new branch.
/// Gathers parent summary + recent messages up to the fork point.
@MainActor
enum ContextBuilder {

    /// Build the context string to inject as a system message in a new branch.
    ///
    /// - Parameters:
    ///   - parentBranch: The branch being forked from
    ///   - forkMessageId: The message to fork from (context includes this message and prior)
    ///   - depth: How many recent messages to include (default: Constants.defaultContextDepth)
    /// - Returns: Formatted context string for system message injection
    static func buildForkContext(
        parentBranch: Branch,
        forkMessageId: String,
        depth: Int = CortanaConstants.defaultContextDepth
    ) throws -> String {
        guard let sessionId = parentBranch.sessionId else {
            return "[New branch — no parent context]"
        }

        var sections: [String] = []

        // Section 1: Branch metadata
        sections.append("""
            [Context from branch '\(parentBranch.displayTitle)']
            Branch type: \(parentBranch.branchType.rawValue)
            Created: \(parentBranch.createdAt.formatted())
            """)

        // Section 2: Session summary (if available)
        if let summary = try MessageStore.shared.getSessionSummary(sessionId: sessionId) {
            sections.append("""
                [Summary]
                \(summary)
                """)
        }

        // Section 3: Recent messages up to fork point
        let messages = try MessageStore.shared.getMessagesUpTo(
            sessionId: sessionId,
            messageId: forkMessageId,
            limit: depth
        )

        if !messages.isEmpty {
            let formatted = messages.map { msg in
                let role = msg.role == .user ? "User" : msg.role == .assistant ? "Cortana" : "System"
                let content = truncate(msg.content, max: 500)
                return "[\(role)]: \(content)"
            }.joined(separator: "\n\n")

            sections.append("""
                [Recent conversation (last \(messages.count) messages)]
                \(formatted)
                """)
        }

        // Section 4: Fork point indicator
        sections.append("[You are branching from this point. Continue the conversation in a new direction.]")

        return sections.joined(separator: "\n\n---\n\n")
    }

    /// Build context specifically for implementation branches.
    /// Includes more detail about what needs to be done.
    static func buildImplementationContext(
        parentBranch: Branch,
        forkMessageId: String,
        instruction: String? = nil
    ) throws -> String {
        let baseContext = try buildForkContext(
            parentBranch: parentBranch,
            forkMessageId: forkMessageId,
            depth: 5 // Fewer messages, more focused
        )

        var result = baseContext

        if let instruction, !instruction.isEmpty {
            result += "\n\n---\n\n[Implementation instruction]\n\(instruction)"
        }

        result += "\n\n[This is an implementation branch. Execute the work described above. Focus on code changes, not discussion.]"

        return result
    }

    // MARK: - Child Digest

    /// Build a compact digest from a completed child branch for injection into parent.
    /// Used when a child branch completes and the parent needs a summary of what was accomplished.
    static func buildChildDigest(childBranch: Branch) -> String? {
        guard let summary = childBranch.summary, !summary.isEmpty else { return nil }

        return """
            [Result from \(childBranch.branchType.rawValue) branch '\(childBranch.displayTitle)']
            Status: \(childBranch.status.rawValue)
            \(summary)
            [End branch result]
            """
    }

    // MARK: - Helpers

    private static func truncate(_ text: String, max: Int) -> String {
        if text.count <= max { return text }
        return String(text.prefix(max)) + "..."
    }
}
