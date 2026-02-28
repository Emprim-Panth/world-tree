import Foundation

/// Manages the "one tree per project" invariant for Simple Mode.
/// Finds or creates a canonical tree for each project path,
/// and injects project + cross-project context on first branch creation.
@MainActor
final class SimpleProjectStore {
    static let shared = SimpleProjectStore()

    private let contextLoader = ProjectContextLoader()

    private init() {}

    // MARK: - Public

    /// Returns (treeId, branchId) for the given project, creating them if needed.
    /// The first branch gets project context + active-project summary injected as a system message.
    func resolve(for project: CachedProject) async throws -> (treeId: String, branchId: String) {
        // 1. Find existing tree for this project path
        if let existing = try findExistingEntry(for: project) {
            return existing
        }

        // 2. Build context snapshot (async — git log, dir structure)
        let context = await contextLoader.loadContext(for: project)
        let crossProjectSummary = buildCrossProjectSummary(excludingPath: project.path)
        let snapshot = buildSnapshot(projectContext: context, crossProjectSummary: crossProjectSummary)

        // 3. Create tree + first branch
        let tree = try TreeStore.shared.createTree(
            name: project.name,
            project: project.name,
            workingDirectory: project.path
        )
        let branch = try TreeStore.shared.createBranch(
            treeId: tree.id,
            type: .conversation,
            title: project.name,
            contextSnapshot: snapshot,
            workingDirectory: project.path
        )
        return (treeId: tree.id, branchId: branch.id)
    }

    // MARK: - Private

    /// Looks for a canvas_tree whose working_directory matches the project path
    /// and returns its first active branch.
    private func findExistingEntry(for project: CachedProject) throws -> (treeId: String, branchId: String)? {
        let trees = try TreeStore.shared.getTrees()
        guard let tree = trees.first(where: { $0.workingDirectory == project.path }) else {
            return nil
        }
        // Get the full tree with its branches
        guard let fullTree = try TreeStore.shared.getTree(tree.id) else { return nil }
        // Return the first active branch (root branch)
        if let branch = fullTree.branches.first(where: { $0.status == .active }) {
            return (treeId: tree.id, branchId: branch.id)
        }
        // All branches archived — create a fresh branch (no new context injection needed)
        let branch = try TreeStore.shared.createBranch(
            treeId: tree.id,
            type: .conversation,
            title: project.name,
            workingDirectory: project.path
        )
        return (treeId: tree.id, branchId: branch.id)
    }

    /// Build a brief summary of all other active projects for cross-project awareness.
    private func buildCrossProjectSummary(excludingPath: String) -> String {
        guard let allTrees = try? TreeStore.shared.getTrees(), !allTrees.isEmpty else {
            return ""
        }
        let others = allTrees.filter { $0.workingDirectory != excludingPath && !($0.workingDirectory ?? "").isEmpty }
        guard !others.isEmpty else { return "" }

        var lines = ["## Active Projects (cross-project context)"]
        for tree in others.prefix(10) {
            var line = "- **\(tree.name)**"
            if let snippet = tree.lastMessageSnippet {
                let preview = String(snippet.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                line += ": \(preview)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Combine project context + cross-project summary into the system message snapshot.
    private func buildSnapshot(projectContext: ProjectContext, crossProjectSummary: String) -> String {
        var parts: [String] = [projectContext.formatForClaude()]
        if !crossProjectSummary.isEmpty {
            parts.append(crossProjectSummary)
        }
        return parts.joined(separator: "\n\n")
    }
}
