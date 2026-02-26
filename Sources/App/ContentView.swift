import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @StateObject private var approvalCoordinator = ApprovalCoordinator.shared

    var body: some View {
        Group {
            if appState.simpleMode {
                SimpleModeView()
            } else {
                advancedView
            }
        }
        .sheet(item: $approvalCoordinator.pendingRequest) { request in
            ApprovalSheet(
                assessment: request.assessment,
                command: request.command,
                onApprove: { remember in
                    approvalCoordinator.resolve(approved: true, remember: remember)
                },
                onDeny: {
                    approvalCoordinator.resolve(approved: false, remember: false)
                }
            )
        }
        .sheet(item: $approvalCoordinator.pendingFileDiff) { request in
            FileDiffSheet(request: request)
        }
    }

    private var advancedView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            if let treeId = appState.selectedTreeId {
                // .id() keyed on both tree and branch forces SwiftUI to fully recreate
                // SingleDocumentView (and its @StateObject viewModel) whenever either changes.
                // With the WKWebView pool cap (max 8), recreation cost is now bounded.
                let selectedBranchId = appState.selectedBranchId ?? ""
                SingleDocumentView(treeId: treeId, branchId: appState.selectedBranchId)
                    .id("\(treeId)-\(selectedBranchId)")
            } else {
                switch appState.sidebarDestination {
                case .commandCenter:
                    CommandCenterView()
                case .timeline:
                    TimelineView()
                case .graph:
                    GraphView()
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.showGlobalSearch },
            set: { appState.showGlobalSearch = $0 }
        )) {
            GlobalSearchView()
                .environment(appState)
                .frame(minWidth: 600, minHeight: 400)
        }
    }
}
