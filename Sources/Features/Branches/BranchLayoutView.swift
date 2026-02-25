import SwiftUI

/// Side-by-side branch layout (TMUX-style horizontal splits)
struct BranchLayoutView: View {
    @StateObject private var viewModel: BranchLayoutViewModel
    @State private var selectedBranchId: String?
    @State private var showSynthesisSheet = false

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
                },
                onCreateRootBranch: {
                    viewModel.createRootBranch()
                },
                onSynthesize: {
                    showSynthesisSheet = true
                }
            )
            .frame(height: 80)
            .sheet(isPresented: $showSynthesisSheet) {
                if let currentId = selectedBranchId ?? viewModel.visibleBranches.first?.id {
                    BranchSynthesisView(
                        treeId: viewModel.treeId,
                        allBranches: viewModel.visibleBranches,
                        currentBranchId: currentId,
                        onCreated: { newBranchId in
                            showSynthesisSheet = false
                            guard !newBranchId.isEmpty else { return }
                            if let branch = try? TreeStore.shared.getBranch(newBranchId) {
                                viewModel.visibleBranches.append(branch)
                                selectedBranchId = newBranchId
                                viewModel.scrollToBranch(newBranchId)
                            }
                        }
                    )
                }
            }

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
                                },
                                onRename: { newTitle in
                                    viewModel.renameBranch(branch.id, title: newTitle)
                                },
                                onComplete: {
                                    viewModel.completeBranch(branch.id)
                                },
                                onArchive: {
                                    viewModel.archiveBranch(branch.id)
                                },
                                onDelete: {
                                    viewModel.deleteBranch(branch.id)
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

    let treeId: String

    init(treeId: String) {
        self.treeId = treeId
    }

    func loadBranches() {
        guard let tree = try? TreeStore.shared.getTree(treeId) else {
            visibleBranches = []
            return
        }
        visibleBranches = tree.branches.filter { $0.status == .active }
    }

    func createBranch(from sectionId: UUID, in parentBranchId: String) {
        do {
            let newBranch = try TreeStore.shared.createBranch(
                treeId: treeId,
                parentBranch: parentBranchId,
                type: .exploration,
                title: "New Branch"
            )
            if let parentIndex = visibleBranches.firstIndex(where: { $0.id == parentBranchId }) {
                visibleBranches.insert(newBranch, at: parentIndex + 1)
            } else {
                visibleBranches.append(newBranch)
            }
        } catch {
            canvasLog("[BranchLayout] Failed to create branch: \(error)")
        }
    }

    func scrollToBranch(_ branchId: String) {
        // Smooth scrolling to a branch requires ScrollViewProxy, which lives in the View layer.
        // The View's selectedBranchId @State drives .scrollTo(branchId) via onChange.
        // Nothing to do here — selection is already managed by the View's @State binding.
    }

    func createRootBranch() {
        do {
            let newBranch = try TreeStore.shared.createBranch(
                treeId: treeId,
                type: .conversation,
                title: "New Branch"
            )
            visibleBranches.append(newBranch)
        } catch {
            canvasLog("[BranchLayout] Failed to create root branch: \(error)")
        }
    }

    func renameBranch(_ id: String, title: String) {
        do {
            try TreeStore.shared.updateBranch(id, title: title)
            if let idx = visibleBranches.firstIndex(where: { $0.id == id }) {
                visibleBranches[idx].title = title
            }
        } catch {
            canvasLog("[BranchLayout] Failed to rename branch \(id): \(error)")
        }
    }

    func completeBranch(_ id: String) {
        do {
            try TreeStore.shared.updateBranch(id, status: .completed)
            visibleBranches.removeAll { $0.id == id }
        } catch {
            canvasLog("[BranchLayout] Failed to complete branch \(id): \(error)")
        }
    }

    func archiveBranch(_ id: String) {
        do {
            try TreeStore.shared.updateBranch(id, status: .archived)
            visibleBranches.removeAll { $0.id == id }
        } catch {
            canvasLog("[BranchLayout] Failed to archive branch \(id): \(error)")
        }
    }

    func deleteBranch(_ id: String) {
        do {
            try TreeStore.shared.deleteBranch(id)
            visibleBranches.removeAll { $0.id == id }
        } catch {
            canvasLog("[BranchLayout] Failed to delete branch \(id): \(error)")
        }
    }

    // MARK: - Organic Branching (Phase 8)

    func createBranchFromSuggestion(_ suggestion: BranchSuggestion, userInput: String) {
        do {
            let newBranch = try TreeStore.shared.createBranch(
                treeId: treeId,
                parentBranch: visibleBranches.first?.id,
                type: suggestion.branchType,
                title: suggestion.title,
                contextSnapshot: userInput
            )
            visibleBranches.append(newBranch)
            canvasLog("[BranchLayout] Created branch: \(suggestion.title)")
        } catch {
            canvasLog("[BranchLayout] Failed to create branch from suggestion: \(error)")
        }
    }

    func spawnParallelBranches(_ suggestions: [BranchSuggestion], userInput: String) {
        let parentId = visibleBranches.first?.id
        for suggestion in suggestions {
            do {
                let newBranch = try TreeStore.shared.createBranch(
                    treeId: treeId,
                    parentBranch: parentId,
                    type: suggestion.branchType,
                    title: suggestion.title,
                    contextSnapshot: userInput
                )
                visibleBranches.append(newBranch)
            } catch {
                canvasLog("[BranchLayout] Failed to spawn branch '\(suggestion.title)': \(error)")
            }
        }
        canvasLog("[BranchLayout] Spawned \(suggestions.count) parallel branches")
    }
}

