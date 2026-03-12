import Foundation
import GRDB

// MARK: - Branch Comparison Result

/// Represents the comparison between two conversation branches.
struct BranchComparison {
    let branchA: Branch
    let branchB: Branch

    /// Messages unique to branch A (after the fork point)
    let uniqueToA: [Message]
    /// Messages unique to branch B (after the fork point)
    let uniqueToB: [Message]
    /// Messages shared between both branches (before the fork point)
    let shared: [Message]

    /// Key topics discussed in each branch (extracted from assistant messages)
    let topicsA: [String]
    let topicsB: [String]

    /// Potential conflicts — similar topics discussed with different conclusions
    let conflicts: [MergeConflict]

    var totalMessagesA: Int { shared.count + uniqueToA.count }
    var totalMessagesB: Int { shared.count + uniqueToB.count }
    var divergencePoint: Int { shared.count }
}

/// A potential conflict between two branches.
struct MergeConflict {
    let topic: String
    let messageFromA: Message
    let messageFromB: Message
    let description: String
}

/// Result of extracting knowledge from a branch.
struct BranchKnowledgeExtraction {
    let branchId: String
    let decisions: [ExtractedInsight]
    let patterns: [ExtractedInsight]
    let insights: [ExtractedInsight]
}

struct ExtractedInsight {
    let messageId: String
    let content: String
    let type: String // DECISION, PATTERN, INSIGHT
    let confidence: Double
}

// MARK: - BranchMergeService

/// Provides branch comparison, knowledge extraction, and merge capabilities.
@MainActor
final class BranchMergeService {
    static let shared = BranchMergeService()

    private var db: DatabaseManager { .shared }
    private let messageStore = MessageStore.shared

    private init() {}

    // MARK: - Compare

    /// Compare two branches, finding shared history and divergent content.
    func compare(branchAId: String, branchBId: String) async throws -> BranchComparison {
        guard let pool = db.dbPool else {
            throw MergeError.databaseUnavailable
        }

        let (branchA, branchB) = try await pool.read { db in
            guard let a = try Branch.fetchOne(db, sql: "SELECT * FROM canvas_branches WHERE id = ?", arguments: [branchAId]),
                  let b = try Branch.fetchOne(db, sql: "SELECT * FROM canvas_branches WHERE id = ?", arguments: [branchBId]) else {
                throw MergeError.branchNotFound
            }
            return (a, b)
        }

        guard let sessionA = branchA.sessionId, let sessionB = branchB.sessionId else {
            throw MergeError.noSession
        }

        let messagesA = try messageStore.getMessages(sessionId: sessionA, limit: 2000)
        let messagesB = try messageStore.getMessages(sessionId: sessionB, limit: 2000)

        // Find the fork point — last shared message
        let forkPoint = findForkPoint(messagesA: messagesA, messagesB: messagesB, branchA: branchA, branchB: branchB)

        let shared = Array(messagesA.prefix(forkPoint))
        let uniqueToA = Array(messagesA.dropFirst(forkPoint))
        let uniqueToB = Array(messagesB.dropFirst(forkPoint))

        // Extract topics from assistant messages
        let topicsA = extractTopics(from: uniqueToA)
        let topicsB = extractTopics(from: uniqueToB)

        // Detect potential conflicts
        let conflicts = detectConflicts(uniqueToA: uniqueToA, uniqueToB: uniqueToB, topicsA: topicsA, topicsB: topicsB)

        return BranchComparison(
            branchA: branchA,
            branchB: branchB,
            uniqueToA: uniqueToA,
            uniqueToB: uniqueToB,
            shared: shared,
            topicsA: topicsA,
            topicsB: topicsB,
            conflicts: conflicts
        )
    }

    // MARK: - Extract Knowledge

    /// Extract decisions, patterns, and insights from a branch's conversation.
    func extractKnowledge(branchId: String) async throws -> BranchKnowledgeExtraction {
        guard let pool = db.dbPool else {
            throw MergeError.databaseUnavailable
        }

        let branch = try await pool.read { db in
            try Branch.fetchOne(db, sql: "SELECT * FROM canvas_branches WHERE id = ?", arguments: [branchId])
        }
        guard let branch, let sessionId = branch.sessionId else {
            throw MergeError.branchNotFound
        }

        let messages = try messageStore.getMessages(sessionId: sessionId, limit: 2000)
        let assistantMessages = messages.filter { $0.role == .assistant }

        var decisions: [ExtractedInsight] = []
        var patterns: [ExtractedInsight] = []
        var insights: [ExtractedInsight] = []

        for msg in assistantMessages {
            let content = msg.content.lowercased()

            // Decision detection
            if content.contains("decided") || content.contains("decision:") ||
               content.contains("we'll go with") || content.contains("choosing") ||
               content.contains("the approach is") {
                decisions.append(ExtractedInsight(
                    messageId: msg.id,
                    content: extractRelevantSentences(msg.content, keywords: ["decided", "decision", "go with", "choosing", "approach"]),
                    type: "DECISION",
                    confidence: 0.7
                ))
            }

            // Pattern detection
            if content.contains("pattern") || content.contains("always use") ||
               content.contains("the fix is") || content.contains("solution:") ||
               content.contains("this works because") {
                patterns.append(ExtractedInsight(
                    messageId: msg.id,
                    content: extractRelevantSentences(msg.content, keywords: ["pattern", "always", "fix", "solution", "works because"]),
                    type: "PATTERN",
                    confidence: 0.6
                ))
            }

            // Insight detection
            if content.contains("important:") || content.contains("note:") ||
               content.contains("key insight") || content.contains("lesson learned") ||
               content.contains("turns out") {
                insights.append(ExtractedInsight(
                    messageId: msg.id,
                    content: extractRelevantSentences(msg.content, keywords: ["important", "note", "insight", "lesson", "turns out"]),
                    type: "INSIGHT",
                    confidence: 0.5
                ))
            }
        }

        return BranchKnowledgeExtraction(
            branchId: branchId,
            decisions: decisions,
            patterns: patterns,
            insights: insights
        )
    }

    // MARK: - Merge Summary

    /// Generate a merge summary combining insights from two branches.
    /// Returns a context snapshot suitable for injection into a new branch.
    func mergeSummary(comparison: BranchComparison) -> String {
        var summary = "## Branch Merge Context\n\n"

        summary += "### Branch A: \(comparison.branchA.displayTitle)\n"
        summary += "Messages: \(comparison.totalMessagesA) (\(comparison.uniqueToA.count) unique)\n"
        if !comparison.topicsA.isEmpty {
            summary += "Topics: \(comparison.topicsA.joined(separator: ", "))\n"
        }
        summary += "\n"

        summary += "### Branch B: \(comparison.branchB.displayTitle)\n"
        summary += "Messages: \(comparison.totalMessagesB) (\(comparison.uniqueToB.count) unique)\n"
        if !comparison.topicsB.isEmpty {
            summary += "Topics: \(comparison.topicsB.joined(separator: ", "))\n"
        }
        summary += "\n"

        summary += "### Shared History\n"
        summary += "\(comparison.shared.count) messages before divergence.\n\n"

        if !comparison.conflicts.isEmpty {
            summary += "### Potential Conflicts\n"
            for conflict in comparison.conflicts {
                summary += "- **\(conflict.topic)**: \(conflict.description)\n"
            }
            summary += "\n"
        }

        // Include key assistant messages from each branch
        summary += "### Key Points from Branch A\n"
        for msg in comparison.uniqueToA.filter({ $0.role == .assistant }).prefix(5) {
            let preview = String(msg.content.prefix(300)).replacingOccurrences(of: "\n", with: " ")
            summary += "- \(preview)\n"
        }
        summary += "\n"

        summary += "### Key Points from Branch B\n"
        for msg in comparison.uniqueToB.filter({ $0.role == .assistant }).prefix(5) {
            let preview = String(msg.content.prefix(300)).replacingOccurrences(of: "\n", with: " ")
            summary += "- \(preview)\n"
        }

        return summary
    }

    // MARK: - Create Merged Branch

    /// Create a new branch that merges context from two branches.
    /// The new branch starts with a context snapshot summarizing both branches.
    func createMergedBranch(
        treeId: String,
        branchAId: String,
        branchBId: String,
        title: String? = nil
    ) async throws -> Branch {
        let comparison = try await compare(branchAId: branchAId, branchBId: branchBId)
        let contextSnapshot = mergeSummary(comparison: comparison)

        let mergeTitle = title ?? "Merge: \(comparison.branchA.displayTitle) + \(comparison.branchB.displayTitle)"

        let branch = try TreeStore.shared.createBranch(
            treeId: treeId,
            parentBranch: comparison.branchA.parentBranchId,
            type: .conversation,
            title: mergeTitle,
            model: comparison.branchA.model,
            contextSnapshot: contextSnapshot
        )

        wtLog("[BranchMerge] Created merged branch \(branch.id.prefix(8)) from \(branchAId.prefix(8)) + \(branchBId.prefix(8))")
        return branch
    }

    // MARK: - Private Helpers

    private func findForkPoint(messagesA: [Message], messagesB: [Message], branchA: Branch, branchB: Branch) -> Int {
        // If one branch forked from the other, use the fork message
        if let forkMsgId = branchB.forkFromMessageId,
           let idx = messagesA.firstIndex(where: { $0.id == forkMsgId }) {
            return messagesA.distance(from: messagesA.startIndex, to: idx) + 1
        }
        if let forkMsgId = branchA.forkFromMessageId,
           let idx = messagesB.firstIndex(where: { $0.id == forkMsgId }) {
            return messagesB.distance(from: messagesB.startIndex, to: idx) + 1
        }

        // Find common ancestor by matching message content
        var shared = 0
        let minLen = min(messagesA.count, messagesB.count)
        for i in 0..<minLen {
            if messagesA[i].content == messagesB[i].content && messagesA[i].role == messagesB[i].role {
                shared = i + 1
            } else {
                break
            }
        }
        return shared
    }

    private func extractTopics(from messages: [Message]) -> [String] {
        let assistantContent = messages
            .filter { $0.role == .assistant }
            .map { $0.content }
            .joined(separator: " ")

        // Simple keyword extraction — look for header-like patterns and key phrases
        var topics: [String] = []
        let lines = assistantContent.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Markdown headers
            if trimmed.hasPrefix("##") || trimmed.hasPrefix("**") {
                let topic = trimmed
                    .replacingOccurrences(of: "#", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if topic.count > 3 && topic.count < 80 {
                    topics.append(topic)
                }
            }
        }
        // Deduplicate and limit
        return Array(Set(topics)).sorted().prefix(10).map { $0 }
    }

    private func detectConflicts(uniqueToA: [Message], uniqueToB: [Message], topicsA: [String], topicsB: [String]) -> [MergeConflict] {
        var conflicts: [MergeConflict] = []

        // Find overlapping topics
        let normalizedA = Set(topicsA.map { $0.lowercased() })
        let normalizedB = Set(topicsB.map { $0.lowercased() })
        let overlapping = normalizedA.intersection(normalizedB)

        for topic in overlapping {
            // Find the first message in each branch that discusses this topic
            let msgA = uniqueToA.first(where: { $0.role == .assistant && $0.content.lowercased().contains(topic) })
            let msgB = uniqueToB.first(where: { $0.role == .assistant && $0.content.lowercased().contains(topic) })

            if let msgA, let msgB {
                conflicts.append(MergeConflict(
                    topic: topic,
                    messageFromA: msgA,
                    messageFromB: msgB,
                    description: "Both branches discuss '\(topic)' — review for contradictions"
                ))
            }
        }

        return conflicts
    }

    private func extractRelevantSentences(_ text: String, keywords: [String]) -> String {
        let sentences = text.components(separatedBy: ". ")
        let relevant = sentences.filter { sentence in
            let lower = sentence.lowercased()
            return keywords.contains(where: { lower.contains($0) })
        }
        return relevant.prefix(3).joined(separator: ". ")
    }
}

// MARK: - Errors

enum MergeError: LocalizedError {
    case databaseUnavailable
    case branchNotFound
    case noSession
    case incompatibleBranches

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable: return "Database not available"
        case .branchNotFound: return "Branch not found"
        case .noSession: return "Branch has no session"
        case .incompatibleBranches: return "Branches cannot be merged"
        }
    }
}
