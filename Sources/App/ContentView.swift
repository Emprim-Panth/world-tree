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
                SingleDocumentView(treeId: treeId)
            } else {
                DashboardView()
            }
        }
        // Phase 6: Voice control - floating overlay
        .voiceEnabled()
    }
}
