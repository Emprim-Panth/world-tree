import Foundation

/// Automatically generates and updates branch names based on conversation content.
@MainActor
final class BranchAutoNamer {
    static let shared = BranchAutoNamer()

    private init() {}

    /// Words that don't carry topic meaning — filtered during keyword extraction.
    private static let stopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "shall", "can", "need", "dare", "ought",
        "i", "me", "my", "we", "us", "our", "you", "your", "he", "she",
        "it", "they", "them", "his", "her", "its", "their", "this", "that",
        "these", "those", "what", "which", "who", "whom", "when", "where",
        "how", "why", "if", "then", "else", "so", "but", "and", "or", "not",
        "no", "nor", "for", "with", "about", "from", "into", "to", "of",
        "in", "on", "at", "by", "up", "out", "off", "over", "under",
        "again", "further", "than", "very", "just", "also", "now", "here",
        "there", "all", "each", "every", "both", "few", "more", "most",
        "some", "any", "no", "only", "same", "other", "such", "too",
        "please", "help", "want", "like", "think", "know", "make", "get",
        "let", "try", "hey", "hi", "hello", "thanks", "thank"
    ]

    // MARK: - Public API

    /// Generate a name for the branch if it hasn't been explicitly named.
    /// Skips branches where the user set a custom title.
    func autoNameIfNeeded(branchId: String) {
        do {
            guard let branch = try TreeStore.shared.getBranch(branchId) else { return }

            // Only auto-name branches with no title or the default "New Branch"
            guard branch.title == nil || branch.title == "New Branch" else { return }

            if let name = try generateName(forBranchId: branchId) {
                try TreeStore.shared.renameBranch(branchId, title: name)
                wtLog("[AutoNamer] Named branch \(branchId.prefix(8)) → \"\(name)\"")
            }
        } catch {
            wtLog("[AutoNamer] autoNameIfNeeded failed for \(branchId.prefix(8)): \(error)")
        }
    }

    /// Check whether the conversation topic has shifted enough to warrant a rename.
    /// Only renames auto-generated titles — never overrides user-chosen names.
    /// Uses Jaccard similarity on keyword sets; <20% overlap = topic shift.
    func suggestRename(forBranchId branchId: String) {
        do {
            guard let branch = try TreeStore.shared.getBranch(branchId),
                  let sessionId = branch.sessionId else { return }

            // Only rename auto-generated titles (no user-set title, or matches "New Branch")
            guard let currentTitle = branch.title,
                  !currentTitle.isEmpty else { return }

            // Skip if user explicitly renamed (compare against what autoName would generate)
            let messages = try MessageStore.shared.getMessages(sessionId: sessionId, limit: 500)
            guard let firstUserMsg = messages.first(where: { $0.role == .user }) else { return }

            let originalName = nameFromContent(firstUserMsg.content)
            guard currentTitle == originalName || currentTitle == "New Branch" else {
                // User set a custom name — don't override
                return
            }

            // Compare keywords from first message vs recent messages
            let firstKeywords = extractKeywords(from: firstUserMsg.content)
            guard !firstKeywords.isEmpty else { return }

            // Use last 5 messages for recent topic detection
            let recentMessages = messages.suffix(5)
            let recentText = recentMessages.map(\.content).joined(separator: " ")
            let recentKeywords = extractKeywords(from: recentText)
            guard !recentKeywords.isEmpty else { return }

            let overlap = jaccardSimilarity(firstKeywords, recentKeywords)

            if overlap < 0.20 {
                // Topic shifted — generate new name from recent content
                let newName = nameFromContent(recentText)
                if newName != currentTitle {
                    try TreeStore.shared.renameBranch(branchId, title: newName)
                    wtLog("[AutoNamer] Topic shift detected (\(String(format: "%.0f%%", overlap * 100)) overlap) — renamed \(branchId.prefix(8)) → \"\(newName)\"")
                }
            }
        } catch {
            wtLog("[AutoNamer] suggestRename failed for \(branchId.prefix(8)): \(error)")
        }
    }

    // MARK: - Name Generation

    /// Load the first user message for a branch and derive a name.
    func generateName(forBranchId branchId: String) throws -> String? {
        guard let branch = try TreeStore.shared.getBranch(branchId),
              let sessionId = branch.sessionId else { return nil }

        let messages = try MessageStore.shared.getMessages(sessionId: sessionId, limit: 20)
        guard let firstUserMsg = messages.first(where: { $0.role == .user }) else { return nil }

        let name = nameFromContent(firstUserMsg.content)
        return name.isEmpty ? nil : name
    }

    /// Extract a concise name (max 50 chars) from message content.
    /// Uses sentence boundary first, then word boundary truncation.
    func nameFromContent(_ content: String) -> String {
        let maxLength = 50

        // Clean up the content — strip code blocks, URLs, excessive whitespace
        var cleaned = content
            .replacingOccurrences(of: "```[\\s\\S]*?```", with: "", options: .regularExpression)
            .replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "`[^`]+`", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Take first line only (multi-line messages usually have the topic on line 1)
        if let firstLine = cleaned.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            cleaned = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Already short enough
        if cleaned.count <= maxLength {
            return cleaned.isEmpty ? "" : cleaned
        }

        // Try sentence boundary (first sentence)
        let sentenceEnders: [Character] = [".", "!", "?"]
        for (i, char) in cleaned.enumerated() {
            if sentenceEnders.contains(char) && i > 10 && i < maxLength {
                return String(cleaned.prefix(i + 1))
            }
        }

        // Fall back to word boundary
        let truncated = String(cleaned.prefix(maxLength))
        if let lastSpace = truncated.lastIndex(of: " ") {
            let wordBounded = String(truncated[truncated.startIndex..<lastSpace])
            return wordBounded + "..."
        }

        return truncated + "..."
    }

    // MARK: - Keyword Analysis

    private func extractKeywords(from text: String) -> Set<String> {
        let words = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !Self.stopWords.contains($0) }

        return Set(words)
    }

    private func jaccardSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }
}
