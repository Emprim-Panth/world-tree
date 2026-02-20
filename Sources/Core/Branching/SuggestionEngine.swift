import Foundation

/// Analyzes user input to detect branching opportunities
actor SuggestionEngine {
    static let shared = SuggestionEngine()

    private init() {}

    /// Natural language patterns that trigger auto-branching
    private let branchTriggers: [String: BranchTrigger] = [
        "try both": .parallelExploration(count: 2),
        "both approaches": .parallelExploration(count: 2),
        "compare": .comparison,
        "what if": .hypothetical,
        "or we could": .alternative,
        "alternatively": .alternative,
        "two ways": .parallelExploration(count: 2),
        "three options": .parallelExploration(count: 3),
        "vs": .comparison
    ]

    /// Analyzes input and returns branch suggestions.
    /// Only fires on explicit trigger phrases — implicit detection was too noisy.
    func analyzeBranchOpportunity(_ text: String) async -> BranchOpportunity? {
        guard text.count > 8 else { return nil }
        let lowercased = text.lowercased()

        for (trigger, type) in branchTriggers {
            if lowercased.contains(trigger) {
                return BranchOpportunity(
                    trigger: trigger,
                    type: type,
                    suggestions: await generateSuggestions(for: text, type: type)
                )
            }
        }

        return nil
    }

    /// Generate branch suggestions based on the trigger type
    private func generateSuggestions(for text: String, type: BranchTrigger) async -> [BranchSuggestion] {
        switch type {
        case .parallelExploration(let count):
            return await generateParallelSuggestions(text, count: count)
        case .comparison:
            return await generateComparisonSuggestions(text)
        case .hypothetical:
            return await generateHypotheticalSuggestions(text)
        case .alternative, .implicit:
            return await generateAlternativeSuggestions(text)
        }
    }

    private func generateParallelSuggestions(_ text: String, count: Int) async -> [BranchSuggestion] {
        let topic = extractTopic(from: text)
        let labels = ["First approach", "Second approach", "Third approach"]
        return (0..<min(count, labels.count)).map { i in
            BranchSuggestion(
                id: UUID(),
                title: "\(labels[i]): \(topic)",
                preview: "Branch and explore this direction independently",
                confidence: 0.8,
                branchType: .exploration
            )
        }
    }

    private func generateComparisonSuggestions(_ text: String) async -> [BranchSuggestion] {
        let components = extractComparisonComponents(from: text)
        return components.map { component in
            BranchSuggestion(
                id: UUID(),
                title: component,
                preview: "Explore \(component) in its own branch",
                confidence: 0.85,
                branchType: .exploration
            )
        }
    }

    private func generateHypotheticalSuggestions(_ text: String) async -> [BranchSuggestion] {
        let scenario = extractHypothetical(from: text)
        return [
            BranchSuggestion(
                id: UUID(),
                title: "What if: \(scenario)",
                preview: "Explore this hypothetical in a separate branch",
                confidence: 0.75,
                branchType: .exploration
            )
        ]
    }

    private func generateAlternativeSuggestions(_ text: String) async -> [BranchSuggestion] {
        let topic = extractTopic(from: text)
        return [
            BranchSuggestion(
                id: UUID(),
                title: "Alternative: \(topic)",
                preview: "Try a different approach in a new branch",
                confidence: 0.7,
                branchType: .exploration
            )
        ]
    }

    // MARK: - Extraction Helpers

    private func extractTopic(from text: String) -> String {
        // Strip trigger phrases, take the meaningful remainder
        let triggers = ["try both", "both approaches", "compare", "what if", "or we could",
                        "alternatively", "two ways", "three options", "vs"]
        var cleaned = text
        for t in triggers {
            cleaned = cleaned.replacingOccurrences(of: t, with: "", options: .caseInsensitive)
        }
        let words = cleaned.split(separator: " ").filter { $0.count > 2 }.map(String.init)
        let meaningful = words.suffix(4).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return meaningful.isEmpty ? "this approach" : meaningful
    }

    private func extractComparisonComponents(from text: String) -> [String] {
        let lowercased = text.lowercased()
        // "X vs Y" pattern
        if let vsRange = lowercased.range(of: " vs ") {
            let before = String(text[..<vsRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let after = String(text[vsRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            let a = before.components(separatedBy: " ").suffix(2).joined(separator: " ")
            let b = after.components(separatedBy: " ").prefix(2).joined(separator: " ")
            if !a.isEmpty && !b.isEmpty { return [a, b] }
        }
        // "compare X and Y" pattern
        if let compareRange = lowercased.range(of: "compare ") {
            let remainder = String(text[compareRange.upperBound...])
            let parts = remainder.components(separatedBy: " and ")
            if parts.count >= 2 {
                return [parts[0].trimmingCharacters(in: .whitespaces),
                        parts[1].trimmingCharacters(in: .whitespaces)]
            }
        }
        let topic = extractTopic(from: text)
        return [topic, "Alternative to \(topic)"]
    }

    private func extractHypothetical(from text: String) -> String {
        let lowercased = text.lowercased()
        if let whatIfRange = lowercased.range(of: "what if ") {
            let scenario = String(text[whatIfRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            return scenario.isEmpty ? "this scenario" : scenario
        }
        return extractTopic(from: text)
    }
}

// MARK: - Models

enum BranchTrigger {
    case parallelExploration(count: Int)
    case comparison
    case hypothetical
    case alternative
    case implicit
}

struct BranchOpportunity {
    let trigger: String
    let type: BranchTrigger
    let suggestions: [BranchSuggestion]
}

struct BranchSuggestion: Identifiable {
    let id: UUID
    let title: String
    let preview: String
    let confidence: Double
    let branchType: BranchType
}
