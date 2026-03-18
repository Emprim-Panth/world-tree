import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @StateObject private var approvalCoordinator = ApprovalCoordinator.shared

    var body: some View {
        advancedView
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
                .accessibilityLabel("Sidebar")
        } detail: {
            // .id() at this level forces SwiftUI to fully recreate DetailRouter
            // (and everything inside it) whenever the selection changes.
            // NavigationSplitView instantiates the detail closure in multiple layout
            // passes — relying on @Observable propagation alone is unreliable.
            // Keying on selection here is the only guarantee of a correct re-render.
            DetailRouter()
                .id((appState.selectedTreeId ?? "none") + "-" + (appState.selectedBranchId ?? "none"))
        }
        // Toolbar lives here — above NavigationSplitView — so it is applied exactly
        // once per window. Putting .toolbar inside the detail column view causes
        // macOS to duplicate the items because the detail closure is evaluated in
        // multiple layout contexts (sidebar-visible and sidebar-hidden states).
        .toolbar {
            if appState.selectedTreeId != nil {
                ToolbarItem(placement: .secondaryAction) {
                    ModelPickerButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            appState.terminalVisible.toggle()
                        }
                    } label: {
                        Label("Claude", systemImage: appState.terminalVisible ? "terminal.fill" : "terminal")
                    }
                    .keyboardShortcut("`", modifiers: .command)
                    .help("Open Claude terminal (⌘`)")
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

/// Routes the detail column based on AppState selection.
/// Extracted as a separate view so @Observable tracking on AppState
/// is properly scoped — NavigationSplitView's detail closure does not
/// reliably invalidate on @Observable changes.
private struct DetailRouter: View {
    @Environment(AppState.self) var appState

    var body: some View {
        if let treeId = appState.selectedTreeId {
            // .id() keyed on both tree and branch forces SwiftUI to fully recreate
            // SingleDocumentView (and its @StateObject viewModel) whenever either changes.
            let selectedBranchId = appState.selectedBranchId ?? ""
            SingleDocumentView(treeId: treeId, branchId: appState.selectedBranchId)
                .id("\(treeId)-\(selectedBranchId)")
        } else {
            switch appState.sidebarDestination {
            case .commandCenter:
                CommandCenterView()
            case .projectDocs:
                if let projectName = appState.selectedProjectName {
                    ProjectDocsView(projectName: projectName, workingDirectory: appState.selectedProjectPath)
                } else {
                    CommandCenterView()
                }
            case .tickets:
                AllTicketsView()
            case .timeline:
                EventTimelineView()
            case .mcpTools:
                MCPToolsView()
            case .brain:
                BrainView()
            }
        }
    }
}
