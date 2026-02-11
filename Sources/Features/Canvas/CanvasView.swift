import SwiftUI

/// Main canvas area — displays the selected branch's conversation
struct CanvasView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let branchId = appState.selectedBranchId {
            BranchView(branchId: branchId)
                .id(branchId) // Force recreation on branch change
        } else {
            VStack(spacing: 16) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.cyan.opacity(0.5))

                Text("Select a branch or create a new tree")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text("Cmd+N to create a new tree")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
