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

    /// Analyzes input and returns branch suggestions
    func analyzeBranchOpportunity(_ text: String) async -> BranchOpportunity? {
        let lowercased = text.lowercased()

        // Check for explicit trigger phrases
        for (trigger, type) in branchTriggers {
            if lowercased.contains(trigger) {
                return BranchOpportunity(
                    trigger: trigger,
                    type: type,
                    suggestions: await generateSuggestions(for: text, type: type)
                )
            }
        }

        // Check for implicit branching (multiple approaches detected)
        if await hasMultipleApproaches(text) {
            return BranchOpportunity(
                trigger: "detected",
                type: .implicit,
                suggestions: await generateSuggestions(for: text, type: .implicit)
            )
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
        case .alternative:
            return await generateAlternativeSuggestions(text)
        case .implicit:
            return await generateImplicitSuggestions(text)
        }
    }

    private func generateParallelSuggestions(_ text: String, count: Int) async -> [BranchSuggestion] {
        // Extract the topic being discussed
        let topic = extractTopic(from: text)

        // Generate N different approaches
        var suggestions: [BranchSuggestion] = []

        for i in 1...count {
            suggestions.append(BranchSuggestion(
                id: UUID(),
                title: "Approach \(i): \(topic)",
                preview: "Exploring \(topic) from angle \(i)...",
                confidence: 0.8,
                branchType: .exploration
            ))
        }

        return suggestions
    }

    private func generateComparisonSuggestions(_ text: String) async -> [BranchSuggestion] {
        // Extract the things being compared
        let components = extractComparisonComponents(from: text)

        return components.enumerated().map { index, component in
            BranchSuggestion(
                id: UUID(),
                title: component,
                preview: "Deep dive into \(component)...",
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
                title: "Explore: \(scenario)",
                preview: "What if \(scenario)...",
                confidence: 0.75,
                branchType: .exploration
            )
        ]
    }

    private func generateAlternativeSuggestions(_ text: String) async -> [BranchSuggestion] {
        return [
            BranchSuggestion(
                id: UUID(),
                title: "Alternative Approach",
                preview: "Exploring alternative path...",
                confidence: 0.7,
                branchType: .exploration
            )
        ]
    }

    private func generateImplicitSuggestions(_ text: String) async -> [BranchSuggestion] {
        // Detect if there are multiple valid approaches
        return [
            BranchSuggestion(
                id: UUID(),
                title: "Option A",
                preview: "Standard approach...",
                confidence: 0.6,
                branchType: .exploration
            ),
            BranchSuggestion(
                id: UUID(),
                title: "Option B",
                preview: "Alternative approach...",
                confidence: 0.6,
                branchType: .exploration
            )
        ]
    }

    // MARK: - Analysis Helpers

    private func hasMultipleApproaches(_ text: String) async -> Bool {
        // Simple heuristic: check for choice indicators
        let choiceIndicators = ["or", "either", "could", "might", "perhaps"]
        let lowercased = text.lowercased()

        let count = choiceIndicators.filter { lowercased.contains($0) }.count
        return count >= 2
    }

    private func extractTopic(from text: String) -> String {
        // Simple extraction - take the main subject
        // TODO: Use NLP for better topic extraction
        let words = text.split(separator: " ")
        if words.count > 3 {
            return words.suffix(3).joined(separator: " ")
        }
        return "this topic"
    }

    private func extractComparisonComponents(from text: String) -> [String] {
        // Extract items being compared (e.g., "JWT vs OAuth" -> ["JWT", "OAuth"])
        let lowercased = text.lowercased()

        if let vsRange = lowercased.range(of: " vs ") {
            let before = String(text[..<vsRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let after = String(text[vsRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            return [before, after].map { $0.components(separatedBy: " ").last ?? $0 }
        }

        return ["Option A", "Option B"]
    }

    private func extractHypothetical(from text: String) -> String {
        // Extract the hypothetical scenario after "what if"
        let lowercased = text.lowercased()
        if let whatIfRange = lowercased.range(of: "what if ") {
            return String(text[whatIfRange.upperBound...])
        }
        return "alternative scenario"
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
