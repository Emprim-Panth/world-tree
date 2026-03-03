import SwiftUI

struct BranchesListView: View {
    @Environment(WorldTreeStore.self) private var store
    @Environment(ConnectionManager.self) private var connectionManager

    @State private var branchToRename: BranchSummary?
    @State private var branchToDelete: BranchSummary?
    @State private var renameText = ""

    var body: some View {
        List(store.branches as [BranchSummary]) { (branch: BranchSummary) in
            BranchRow(
                branch: branch,
                onSelect: {
                    store.selectBranch(branch)
                    guard let tree = store.currentTree else { return }
                    Task {
                        await connectionManager.send(.subscribe(treeId: tree.id, branchId: branch.id))
                        await connectionManager.send(.loadHistory(branchId: branch.id))
                    }
                },
                onRename: {
                    branchToRename = branch
                    renameText = branch.displayName
                },
                onDelete: { branchToDelete = branch }
            )
        }
        .refreshable {
            if let treeId = store.currentTree?.id {
                await connectionManager.send(.listBranches(treeId: treeId))
            }
        }
        .overlay {
            if store.isLoadingBranches {
                ProgressView()
                    .progressViewStyle(.circular)
            } else if store.branches.isEmpty {
                ContentUnavailableView(
                    "No Branches",
                    systemImage: "arrow.triangle.branch",
                    description: Text("This conversation has no branches yet.")
                )
            }
        }
        // Rename alert
        .alert("Rename Branch", isPresented: Binding(
            get: { branchToRename != nil },
            set: { if !$0 { branchToRename = nil } }
        )) {
            TextField("Title", text: $renameText)
                .autocorrectionDisabled()
            Button("Rename") {
                if let branch = branchToRename {
                    let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return }
                    Task { await connectionManager.send(.renameBranch(branchId: branch.id, title: title)) }
                }
                branchToRename = nil
            }
            Button("Cancel", role: .cancel) { branchToRename = nil }
        }
        // Delete confirmation
        .alert("Delete Branch", isPresented: Binding(
            get: { branchToDelete != nil },
            set: { if !$0 { branchToDelete = nil } }
        ), presenting: branchToDelete) { branch in
            Button("Delete", role: .destructive) {
                Task { await connectionManager.send(.deleteBranch(branchId: branch.id)) }
                if store.currentBranch?.id == branch.id { store.clearBranch() }
                branchToDelete = nil
            }
            Button("Cancel", role: .cancel) { branchToDelete = nil }
        } message: { branch in
            Text("\"\(branch.displayName)\" and all its messages will be permanently deleted.")
        }
    }
}

// MARK: - Branch Row

private struct BranchRow: View {
    let branch: BranchSummary
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                Text(branch.displayName)
                    .font(.body)
                HStack(spacing: 8) {
                    Text(branch.status.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if branch.branchType != "main" {
                        Text(branch.branchType)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }
}
