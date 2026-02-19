import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            if let treeId = appState.selectedTreeId {
                // .id() keyed on both tree and branch forces SwiftUI to fully recreate
                // SingleDocumentView (and its @StateObject viewModel) whenever either changes.
                // Without the branch component, switching branches within the same tree
                // would leave the old conversation on screen.
                let selectedBranchId = appState.selectedBranchId ?? ""
                SingleDocumentView(treeId: treeId, branchId: appState.selectedBranchId)
                    .id("\(treeId)-\(selectedBranchId)")
            } else {
                DashboardView()
            }
        }
        // Phase 6: Voice control - floating overlay
        .voiceEnabled()
    }
}
