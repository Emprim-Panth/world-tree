import SwiftUI

/// Side-by-side branch layout (TMUX-style horizontal splits)
struct BranchLayoutView: View {
    @StateObject private var viewModel: BranchLayoutViewModel
    @State private var selectedBranchId: String?

    init(treeId: String) {
        _viewModel = StateObject(wrappedValue: BranchLayoutViewModel(treeId: treeId))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Branch navigator (mini-map at top)
            BranchNavigatorView(
                branches: viewModel.visibleBranches,
                selectedBranchId: $selectedBranchId,
                onSelectBranch: { branchId in
                    viewModel.scrollToBranch(branchId)
                }
            )
            .frame(height: 80)

            Divider()

            // Horizontal scrolling columns
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(viewModel.visibleBranches) { branch in
                            BranchColumn(
                                branch: branch,
                                width: 600,
                                isSelected: selectedBranchId == branch.id,
                                onCreateBranch: { sectionId in
                                    viewModel.createBranch(from: sectionId, in: branch.id)
                                },
                                onSelect: {
                                    selectedBranchId = branch.id
                                }
                            )
                            .frame(width: 600)
                            .id(branch.id)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .onAppear {
            viewModel.loadBranches()
        }
    }
}

@MainActor
class BranchLayoutViewModel: ObservableObject {
    @Published var visibleBranches: [Branch] = []

    private let treeId: String

    init(treeId: String) {
        self.treeId = treeId
    }

    func loadBranches() {
        // TODO: Load branches from database
        // For now, create sample branches
        let mainBranch = Branch(
            id: UUID().uuidString,
            treeId: treeId,
            sessionId: UUID().uuidString,
            parentBranchId: nil,
            forkFromMessageId: nil,
            branchType: .conversation,
            title: "Main Conversation",
            status: .active,
            summary: nil,
            model: nil,
            daemonTaskId: nil,
            contextSnapshot: nil,
            collapsed: false,
            createdAt: Date(),
            updatedAt: Date()
        )

        let exploreBranch = Branch(
            id: UUID().uuidString,
            treeId: treeId,
            sessionId: UUID().uuidString,
            parentBranchId: mainBranch.id,
            forkFromMessageId: nil,
            branchType: .exploration,
            title: "Exploration: Alternative approach",
            status: .active,
            summary: nil,
            model: nil,
            daemonTaskId: nil,
            contextSnapshot: nil,
            collapsed: false,
            createdAt: Date(),
            updatedAt: Date()
        )

        visibleBranches = [mainBranch, exploreBranch]
    }

    func createBranch(from sectionId: UUID, in parentBranchId: String) {
        // TODO: Implement branch creation
        // 1. Create new branch in database
        // 2. Copy conversation up to sectionId
        // 3. Add to visibleBranches at appropriate position
        // 4. Animate slide-in from right

        let newBranch = Branch(
            id: UUID().uuidString,
            treeId: treeId,
            sessionId: UUID().uuidString,
            parentBranchId: parentBranchId,
            forkFromMessageId: nil,
            branchType: .exploration,
            title: "New Branch",
            status: .active,
            summary: nil,
            model: nil,
            daemonTaskId: nil,
            contextSnapshot: nil,
            collapsed: false,
            createdAt: Date(),
            updatedAt: Date()
        )

        // Insert after parent
        if let parentIndex = visibleBranches.firstIndex(where: { $0.id == parentBranchId }) {
            visibleBranches.insert(newBranch, at: parentIndex + 1)
        } else {
            visibleBranches.append(newBranch)
        }
    }

    func scrollToBranch(_ branchId: String) {
        // TODO: Implement smooth scrolling to branch
    }

    // MARK: - Organic Branching (Phase 8)

    func createBranchFromSuggestion(_ suggestion: BranchSuggestion, userInput: String) {
        // Create a new branch based on the suggestion
        let newBranch = Branch(
            id: UUID().uuidString,
            treeId: treeId,
            sessionId: UUID().uuidString,
            parentBranchId: visibleBranches.first?.id,
            forkFromMessageId: nil,
            branchType: suggestion.branchType,
            title: suggestion.title,
            status: .active,
            summary: suggestion.preview,
            model: nil,
            daemonTaskId: nil,
            contextSnapshot: userInput,
            collapsed: false,
            createdAt: Date(),
            updatedAt: Date()
        )

        // Add to visible branches (side-by-side)
        visibleBranches.append(newBranch)

        print("✨ Created branch: \(suggestion.title)")
    }

    func spawnParallelBranches(_ suggestions: [BranchSuggestion], userInput: String) {
        // Create multiple branches at once for parallel exploration
        for suggestion in suggestions {
            let newBranch = Branch(
                id: UUID().uuidString,
                treeId: treeId,
                sessionId: UUID().uuidString,
                parentBranchId: visibleBranches.first?.id,
                forkFromMessageId: nil,
                branchType: suggestion.branchType,
                title: suggestion.title,
                status: .active,
                summary: suggestion.preview,
                model: nil,
                daemonTaskId: nil,
                contextSnapshot: userInput,
                collapsed: false,
                createdAt: Date(),
                updatedAt: Date()
            )

            visibleBranches.append(newBranch)
        }

        print("✨ Spawned \(suggestions.count) parallel branches for exploration!")
    }
}

// MARK: - Branch Extensions

extension Branch {
    var depth: Int {
        // Calculate depth by traversing parent chain
        // For now, return 0 (will be populated by TreeStore)
        0
    }

    var messageCount: Int {
        // TODO: Load from database
        0
    }
}
