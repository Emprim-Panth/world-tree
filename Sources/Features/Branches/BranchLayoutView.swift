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
            title: "Main Conversation",
            depth: 0,
            parentBranchId: nil,
            sessionId: UUID().uuidString,
            status: .active,
            createdAt: Date()
        )

        let exploreBranch = Branch(
            id: UUID().uuidString,
            treeId: treeId,
            title: "Exploration: Alternative approach",
            depth: 1,
            parentBranchId: mainBranch.id,
            sessionId: UUID().uuidString,
            status: .active,
            createdAt: Date()
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
            title: "New Branch",
            depth: (visibleBranches.first(where: { $0.id == parentBranchId })?.depth ?? 0) + 1,
            parentBranchId: parentBranchId,
            sessionId: UUID().uuidString,
            status: .active,
            createdAt: Date()
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
}

// MARK: - Branch Model

struct Branch: Identifiable {
    let id: String
    let treeId: String
    var title: String
    var depth: Int  // Nesting level (0 = root, 1 = first fork, etc.)
    var parentBranchId: String?
    var sessionId: String
    var status: BranchStatus
    var summary: String?
    var messageCount: Int = 0
    var createdAt: Date
    var updatedAt: Date = Date()

    enum BranchStatus: String {
        case active
        case completed
        case archived
        case failed
    }
}
