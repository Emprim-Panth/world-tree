import Foundation
import Combine

// MARK: - Context Provenance

/// Records exactly what context was injected on a given send — gameplan, recent messages,
/// checkpoint, scored history, memory recall, and project context.
/// Surfaced in the UI as an inspector so the user can see why Cortana knows (or doesn't know)
/// something in the current conversation.
struct ContextProvenance {
    struct Block: Identifiable {
        let id = UUID()
        let label: String
        /// SF Symbol name for the inspector row icon.
        let icon: String
        /// The actual injected text (empty string = not injected this turn).
        let content: String

        var wasInjected: Bool { !content.isEmpty }
        /// Alias used by ContextInspectorView.
        var isPresent: Bool { wasInjected }
        /// Character count — shown in the inspector summary row.
        var charCount: Int { content.count }
        /// Rough token estimate for the inspector (~4 chars per token).
        var tokenEstimate: Int { max(0, content.count / 4) }
    }

    let timestamp: Date
    let model: String
    let blocks: [Block]

    /// Total characters injected across all blocks.
    var totalChars: Int { blocks.reduce(0) { $0 + $1.charCount } }
    /// Total token estimate across all blocks.
    var totalTokens: Int { blocks.reduce(0) { $0 + $1.tokenEstimate } }

    /// Blocks that were actually injected (non-empty content).
    var injectedBlocks: [Block] { blocks.filter(\.wasInjected) }
}

// MARK: - Provenance Store

/// Lightweight in-memory cache of the last provenance record per branch.
/// Only the most recent send is kept — older records are replaced.
@MainActor
final class ContextProvenanceStore: ObservableObject {
    static let shared = ContextProvenanceStore()
    private init() {}

    @Published private var records: [String: ContextProvenance] = [:]

    /// Record provenance for `branchId`, replacing any prior record.
    func record(_ provenance: ContextProvenance, for branchId: String) {
        records[branchId] = provenance
        wtLog("[ContextProvenance] Recorded for branch \(branchId.prefix(8)): \(provenance.injectedBlocks.count) blocks, \(provenance.totalChars) chars, model=\(provenance.model)")
    }

    /// Retrieve the last provenance record for `branchId`, or nil if none exists.
    func latest(for branchId: String) -> ContextProvenance? {
        records[branchId]
    }

    /// Alias for `latest(for:)` — used by DocumentEditorView.
    func provenance(for branchId: String) -> ContextProvenance? {
        records[branchId]
    }

    /// Clear the record for `branchId` (e.g. on branch deletion).
    func clear(for branchId: String) {
        records.removeValue(forKey: branchId)
    }
}
