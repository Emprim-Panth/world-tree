import Foundation

/// Detects architectural/technical decisions in assistant messages and extracts
/// structured decision records for auto-logging to the memory system.
///
/// Detection uses keyword/phrase patterns that indicate a decision was made,
/// then extracts the decision statement and surrounding rationale context.
/// Runs on a background queue to avoid blocking the UI after message persist.
@MainActor
final class DecisionDetector {
    static let shared = DecisionDetector()

    private init() {}

    /// A detected decision with its context.
    struct DetectedDecision: Sendable {
        let summary: String      // One-line decision statement
        let rationale: String    // Why this decision was made
        let context: String      // Surrounding paragraph for full context
        let confidence: Double   // 0.0–1.0 detection confidence
    }

    // MARK: - Detection Patterns

    /// Phrases that signal a decision is being stated. Ordered by specificity.
    private nonisolated static let decisionSignals: [(pattern: String, weight: Double)] = [
        // Explicit decision language
        ("I decided to", 0.95),
        ("I've decided to", 0.95),
        ("the decision is to", 0.95),
        ("we'll go with", 0.90),
        ("I'll go with", 0.90),
        ("going with", 0.85),
        ("I chose", 0.90),
        ("I've chosen", 0.90),
        ("the approach will be", 0.90),
        ("the approach is to", 0.90),

        // Architecture/design signals
        ("instead of", 0.70),
        ("rather than", 0.70),
        ("the tradeoff", 0.75),
        ("the trade-off", 0.75),
        ("this means we", 0.70),

        // Recommendation that implies decision
        ("I recommend", 0.80),
        ("the best approach", 0.80),
        ("the right approach", 0.80),
        ("should use", 0.65),
        ("will use", 0.75),
        ("let's use", 0.80),

        // Pattern/convention setting
        ("from now on", 0.85),
        ("going forward", 0.85),
        ("the convention is", 0.90),
        ("the pattern is", 0.85),
        ("the standard is", 0.85),
    ]

    /// Phrases that indicate rationale follows.
    private nonisolated static let rationaleSignals: [String] = [
        "because", "since", "the reason", "this is because",
        "the benefit", "the advantage", "this avoids",
        "this prevents", "this ensures", "this allows",
        "the tradeoff", "the trade-off", "the downside",
    ]

    /// Minimum message length to bother scanning (short messages rarely contain decisions).
    private nonisolated static let minimumLength = 150

    /// Minimum confidence to log a decision.
    private nonisolated static let confidenceThreshold = 0.70

    // MARK: - Public API

    /// Scan an assistant message for decisions. Returns detected decisions
    /// above the confidence threshold, sorted by confidence descending.
    nonisolated func detect(in message: String) -> [DetectedDecision] {
        guard message.count >= Self.minimumLength else { return [] }

        let paragraphs = splitIntoParagraphs(message)
        var decisions: [DetectedDecision] = []

        for paragraph in paragraphs {
            let lower = paragraph.lowercased()

            // Find the highest-weight signal in this paragraph
            var bestSignal: (pattern: String, weight: Double)?
            var signalCount = 0

            for signal in Self.decisionSignals {
                if lower.contains(signal.pattern) {
                    signalCount += 1
                    if bestSignal == nil || signal.weight > bestSignal!.weight {
                        bestSignal = signal
                    }
                }
            }

            guard let signal = bestSignal else { continue }

            // Boost confidence if multiple signals appear in the same paragraph
            let multiSignalBoost = min(Double(signalCount - 1) * 0.05, 0.15)

            // Check for rationale presence — decisions with stated rationale are higher confidence
            let hasRationale = Self.rationaleSignals.contains { lower.contains($0) }
            let rationaleBoost = hasRationale ? 0.10 : 0.0

            let confidence = min(signal.weight + multiSignalBoost + rationaleBoost, 1.0)
            guard confidence >= Self.confidenceThreshold else { continue }

            // Extract the decision summary — the sentence containing the signal
            let summary = extractSentence(containing: signal.pattern, in: paragraph)
            let rationale = hasRationale
                ? extractRationale(from: paragraph)
                : "No explicit rationale detected."

            // Deduplicate — skip if we already have a very similar decision
            let isDuplicate = decisions.contains { existing in
                stringSimilarity(existing.summary, summary) > 0.7
            }
            guard !isDuplicate else { continue }

            decisions.append(DetectedDecision(
                summary: summary,
                rationale: rationale,
                context: String(paragraph.prefix(500)),
                confidence: confidence
            ))
        }

        return decisions.sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Text Extraction Helpers

    /// Split message into paragraphs (double-newline separated blocks).
    private nonisolated func splitIntoParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 50 }  // skip tiny fragments
    }

    /// Extract the sentence containing a signal phrase.
    private nonisolated func extractSentence(containing signal: String, in paragraph: String) -> String {
        let lower = paragraph.lowercased()
        guard let signalRange = lower.range(of: signal) else {
            return String(paragraph.prefix(200))
        }

        // Find sentence boundaries around the signal
        let startIndex = signalRange.lowerBound
        let sentenceStart = findSentenceStart(in: paragraph, before: startIndex)
        let sentenceEnd = findSentenceEnd(in: paragraph, after: signalRange.upperBound)

        let sentence = String(paragraph[sentenceStart..<sentenceEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Cap at reasonable length
        if sentence.count > 300 {
            return String(sentence.prefix(300)) + "..."
        }
        return sentence
    }

    /// Extract rationale text from a paragraph.
    private nonisolated func extractRationale(from paragraph: String) -> String {
        let lower = paragraph.lowercased()

        // Find the first rationale signal and extract from there
        for signal in Self.rationaleSignals {
            if let range = lower.range(of: signal) {
                let startIdx = range.lowerBound
                let sentenceEnd = findSentenceEnd(in: paragraph, after: startIdx)
                let rationale = String(paragraph[startIdx..<sentenceEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rationale.count > 300 {
                    return String(rationale.prefix(300)) + "..."
                }
                return rationale
            }
        }
        return "No explicit rationale detected."
    }

    private nonisolated func findSentenceStart(in text: String, before index: String.Index) -> String.Index {
        let terminators: Set<Character> = [".", "!", "?", "\n"]
        var idx = index
        while idx > text.startIndex {
            let prev = text.index(before: idx)
            if terminators.contains(text[prev]) {
                return idx
            }
            idx = prev
        }
        return text.startIndex
    }

    private nonisolated func findSentenceEnd(in text: String, after index: String.Index) -> String.Index {
        let terminators: Set<Character> = [".", "!", "?", "\n"]
        var idx = index
        while idx < text.endIndex {
            if terminators.contains(text[idx]) {
                return text.index(after: idx)
            }
            idx = text.index(after: idx)
        }
        return text.endIndex
    }

    /// Simple Jaccard similarity on word sets.
    private nonisolated func stringSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(separator: " "))
        let wordsB = Set(b.lowercased().split(separator: " "))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 1.0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return Double(intersection) / Double(union)
    }
}
