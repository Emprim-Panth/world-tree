import Foundation

/// Reads messages from multiple branches, builds a cross-branch synthesis prompt,
/// creates a new conversation branch, and auto-sends the prompt.
enum SynthesisService {

    static let maxMessagesPerBranch = 20

    /// Create a synthesis branch, build the context prompt from selected branches,
    /// and return the new branch (caller navigates to it and the prompt auto-fires on load).
    @MainActor
    static func createSynthesisBranch(
        treeId: String,
        parentBranch: Branch,
        selectedBranchIds: [String],
        allBranches: [Branch],
        focusInstruction: String?
    ) async throws -> Branch {

        // 1. Build synthesis context from selected branches
        let prompt = try buildSynthesisPrompt(
            selectedBranchIds: selectedBranchIds,
            allBranches: allBranches,
            focusInstruction: focusInstruction
        )

        // 2. Create a new conversation branch off the parent
        let newBranch = try TreeStore.shared.createBranch(
            treeId: treeId,
            parentBranch: parentBranch.id,
            forkFromMessage: nil,
            type: .conversation,
            title: "Synthesis — \(selectedBranchIds.count) branches",
            model: parentBranch.model ?? AppConstants.defaultModel,
            contextSnapshot: nil,
            workingDirectory: parentBranch.contextSnapshot.flatMap { _ in nil }
        )

        // 3. Store the synthesis prompt as a pending auto-send for this session.
        //    DocumentEditorView picks it up on onAppear and fires it automatically.
        if let sessionId = newBranch.sessionId {
            UserDefaults.standard.set(prompt, forKey: "pending_synthesis_\(sessionId)")
        }

        return newBranch
    }

    // MARK: - Prompt Building

    @MainActor
    private static func buildSynthesisPrompt(
        selectedBranchIds: [String],
        allBranches: [Branch],
        focusInstruction: String?
    ) throws -> String {
        var sections: [String] = []

        for branchId in selectedBranchIds {
            guard let branch = allBranches.first(where: { $0.id == branchId }) else { continue }
            guard let sessionId = branch.sessionId else { continue }

            let messages = (try? MessageStore.shared.getMessages(
                sessionId: sessionId,
                limit: maxMessagesPerBranch
            )) ?? []

            guard !messages.isEmpty else { continue }

            var section = "### Branch: \(branch.displayTitle) (\(branch.branchType.rawValue))\n"
            for msg in messages {
                let roleLabel = msg.role == .user ? "You" : LocalAgentIdentity.name
                let preview = msg.content.count > 800
                    ? String(msg.content.prefix(800)) + "…"
                    : msg.content
                section += "\n**\(roleLabel):** \(preview)"
            }
            sections.append(section)
        }

        guard !sections.isEmpty else {
            throw SynthesisError.noBranchesWithMessages
        }

        let branchSummary = sections.joined(separator: "\n\n---\n\n")
        let focusClause = focusInstruction.map { "\n\nFocus especially on: \($0)" } ?? ""

        return """
        I've been exploring this problem across \(sections.count) parallel branches. \
        Please read each branch and synthesize the best approach into a single, clear recommendation.

        \(branchSummary)

        ---

        Based on what was explored above, please:
        1. Identify the strongest insights from each branch
        2. Highlight any conflicts or trade-offs between approaches
        3. Produce a concrete, actionable recommendation\(focusClause)
        """
    }
}

enum SynthesisError: LocalizedError {
    case noBranchesWithMessages

    var errorDescription: String? {
        switch self {
        case .noBranchesWithMessages:
            return "None of the selected branches have messages to synthesize."
        }
    }
}
