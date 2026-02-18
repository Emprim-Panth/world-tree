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
                // Phase 8: Full-screen document with organic branching
                // .id(treeId) forces SwiftUI to fully recreate SingleDocumentView — and its
                // @StateObject viewModel — when the tree changes. Without this, SwiftUI reuses
                // the same view instance and the old tree's conversation stays on screen.
                SingleDocumentView(treeId: treeId)
                    .id(treeId)
            } else {
                DashboardView()
            }
        }
        // Phase 6: Voice control - floating overlay
        .voiceEnabled()
    }
}
