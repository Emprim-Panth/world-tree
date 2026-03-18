import SwiftUI

struct ContentView: View {
    @StateObject private var approvalCoordinator = ApprovalCoordinator.shared

    var body: some View {
        AppMainContent()
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
}

/// Main window content — owns the NavigationSplitView, toolbar, and global search sheet.
/// Separated from ContentView so the approval-coordinator sheets live at a different
/// layer and the compiler type-checks each modifier chain in isolation.
private struct AppMainContent: View {
    @Environment(AppState.self) var appState
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        SplitContainer(columnVisibility: $columnVisibility)
            .navigationTitle(appState.selectedTreeName ?? "World Tree")
            .toolbar { mainToolbar }
            .sheet(isPresented: Binding(
                get: { appState.showGlobalSearch },
                set: { appState.showGlobalSearch = $0 }
            )) {
                GlobalSearchView()
                    .environment(appState)
                    .frame(minWidth: 600, minHeight: 400)
            }
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
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
            .disabled(appState.selectedTreeId == nil)
        }
    }
}

/// Wraps NavigationSplitView in its own struct so the compiler type-checks the
/// multi-closure init in isolation. Keys DetailRouter on appState.detailRefreshKey —
/// bumped by AppState on every selection change — to force detail pane recreation
/// without relying on @Observable propagation through NavigationSplitView's detail
/// closure, which is unreliable on macOS.
private struct SplitContainer: View {
    @Environment(AppState.self) var appState
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        let key = appState.detailRefreshKey
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
                .accessibilityLabel("Sidebar")
        } detail: {
            DetailRouter()
                .id(key)
        }
    }
}

/// Routes the detail column based on AppState selection.
private struct DetailRouter: View {
    @Environment(AppState.self) var appState

    var body: some View {
        if let treeId = appState.selectedTreeId {
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
