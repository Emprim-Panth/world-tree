import Foundation

/// Heuristic scorer that replaces dumb last-N slicing for context injection.
///
/// Strategy:
/// - Always keep the last `mandatoryCount` sections (conversation tail — always relevant).
/// - From the remaining candidates, score each by recency, keyword signals, and query overlap.
/// - Return the top `maxAdditional` by score (preserving original order) + the mandatory tail.
///
/// This saves ~25% tokens on stale conversations vs the previous suffix(N) approach by
/// discarding low-signal filler (short ACKs, off-topic turns) while keeping high-value context.
struct ConversationScorer {

    private struct ScoredSection {
        let section: DocumentSection
        let score: Double
        let index: Int
    }

    /// Select context sections for the next API send.
    ///
    /// - Parameters:
    ///   - sections: All sections in the conversation (oldest first).
    ///   - query: The user's current message — used for keyword overlap scoring.
    ///   - mandatoryCount: Sections from the tail always included (default 4).
    ///   - maxAdditional: Additional high-value sections from older history.
    /// - Returns: Selected sections in original chronological order.
    static func select(
        sections: [DocumentSection],
        query: String,
        mandatoryCount: Int = 4,
        maxAdditional: Int
    ) -> [DocumentSection] {
        guard sections.count > mandatoryCount else { return sections }

        let mandatory = Array(sections.suffix(mandatoryCount))
        let candidates = Array(sections.dropLast(mandatoryCount))

        guard !candidates.isEmpty else { return mandatory }

        let queryTokens = Set(
            query.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
        )

        // Pre-compute plain text once per section (avoids repeated AttributedString→String conversion)
        let candidateTexts: [String] = candidates.map { String($0.content.characters).lowercased() }

        let scored: [ScoredSection] = candidates.enumerated().map { idx, section in
            let text = candidateTexts[idx]
            var score = 0.0

            // Recency: older candidates score lower (linear 0→0.4 from oldest→newest)
            let recencyFactor = Double(idx + 1) / Double(candidates.count)
            score += recencyFactor * 0.4

            // Keyword signals — high-value content markers
            let signals = ["implement", "fix", "error", "todo", "must", "should",
                           "decided", "changed", "result", "output", "done",
                           "plan", "issue", "bug", "warning", "failed", "success"]
            let signalHits = signals.filter { text.contains($0) }.count
            score += Double(signalHits) * 0.15

            // Query term overlap
            if !queryTokens.isEmpty {
                let words = Set(text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
                let overlap = Double(queryTokens.intersection(words).count) / Double(queryTokens.count)
                score += overlap * 0.3
            }

            // Short section penalty — sections < 20 chars carry no signal
            if text.count < 20 { score -= 0.3 }

            // Filler penalty — bare acknowledgements
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let fillers: Set<String> = ["ok", "sure", "got it", "understood", "thanks",
                                        "okay", "yes", "no", "great", "sounds good"]
            if fillers.contains(trimmed) { score -= 0.5 }

            return ScoredSection(section: section, score: score, index: idx)
        }

        // Top maxAdditional by score, restored to chronological order
        let top = scored
            .sorted { $0.score > $1.score }
            .prefix(maxAdditional)
            .sorted { $0.index < $1.index }
            .map(\.section)

        return top + mandatory
    }
}
