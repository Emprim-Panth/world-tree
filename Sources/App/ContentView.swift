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
        ToolbarItem(placement: .secondaryAction) {
            FactoryStatusChip()
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
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - Section Composite Views

/// Projects section — command center with project list and ticket detail.
struct ProjectsView: View {
    @State private var selectedProject: String? = nil
    @ObservedObject private var ticketStore = TicketStore.shared

    private var projectNames: [String] {
        ticketStore.allProjectNames.sorted { a, b in
            ticketStore.tickets(for: a).count > ticketStore.tickets(for: b).count
        }
    }

    var body: some View {
        HSplitView {
            // Left: sidebar project list with native macOS treatment
            List(projectNames, id: \.self, selection: $selectedProject) { name in
                ProjectListRow(name: name, tickets: ticketStore.tickets(for: name))
            }
            .listStyle(.sidebar)
            .frame(minWidth: 220, maxWidth: 280)

            // Right: detail
            if let project = selectedProject {
                ProjectDetailPanel(project: project)
            } else {
                ContentUnavailableView(
                    "Select a Project",
                    systemImage: "folder.fill",
                    description: Text("Choose a project from the list.")
                )
            }
        }
        .onAppear {
            ticketStore.refresh()
            if selectedProject == nil {
                selectedProject = projectNames.first
            }
        }
        .onChange(of: projectNames) { names in
            if selectedProject == nil { selectedProject = names.first }
        }
    }
}

struct ProjectListRow: View {
    let name: String
    let tickets: [Ticket]

    private var criticalCount: Int { tickets.filter { $0.priority == "critical" }.count }
    private var highCount: Int { tickets.filter { $0.priority == "high" }.count }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                Text("\(tickets.count) open")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if criticalCount > 0 {
                Text("\(criticalCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.red)
                    .clipShape(Capsule())
            } else if highCount > 0 {
                Text("\(highCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

struct ProjectDetailPanel: View {
    let project: String
    @ObservedObject private var ticketStore = TicketStore.shared

    private var tickets: [Ticket] { ticketStore.tickets(for: project) }
    private var criticalCount: Int { tickets.filter { $0.priority == "critical" }.count }
    private var highCount: Int { tickets.filter { $0.priority == "high" }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card header with visual weight
            VStack(alignment: .leading, spacing: 8) {
                Text(project)
                    .font(.title2.bold())

                Label("~/Development/\(project)", systemImage: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    StatBadge(value: tickets.count, label: "open", color: .blue)
                    if criticalCount > 0 { StatBadge(value: criticalCount, label: "critical", color: .red) }
                    if highCount > 0 { StatBadge(value: highCount, label: "high", color: .orange) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.primary.opacity(0.08)), alignment: .bottom)

            // Ticket list fills remaining space
            ScrollView {
                TicketListView(project: project)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
            }
        }
    }
}

struct StatBadge: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Crew section — agent sessions, dispatch status, and crew mail placeholder.
struct CrewView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                AgentStatusBoard()
                ContentUnavailableView(
                    "Crew Mail",
                    systemImage: "envelope.fill",
                    description: Text("Agent-to-agent messaging coming in Phase 2.")
                )
                .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
    }
}

/// System section — Brain, MCP Tools, and health settings.
struct SystemView: View {
    private enum SystemTab: String, CaseIterable {
        case brain = "Brain"
        case mcpTools = "MCP Tools"
    }
    @State private var selectedTab: SystemTab = .brain

    var body: some View {
        VStack(spacing: 0) {
            Picker("System", selection: $selectedTab) {
                ForEach(SystemTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(height: 28)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch selectedTab {
            case .brain:
                VStack(spacing: 0) {
                    Spacer()
                    VStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .fill(Color.purple.opacity(0.1))
                                .frame(width: 80, height: 80)
                            Image(systemName: "brain")
                                .font(.system(size: 36))
                                .foregroundStyle(Color.purple)
                        }
                        VStack(spacing: 8) {
                            Text("Knowledge Base")
                                .font(.title2.bold())
                            Text("Every correction, decision, pattern, and mistake Cortana has learned — searchable from here.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 360)
                        }
                        Text("Powered by NERVE · Available in Phase 2")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(40)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
                    .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
                    .padding(40)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .mcpTools:
                MCPToolsView()
            }
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
            case .factory:
                FactoryPipelineView()
            case .conversations:
                ContentUnavailableView(
                    "Select a Conversation",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a project and branch from the sidebar to open it here.")
                )
            case .projects:
                ProjectsView()
            case .crew:
                CrewView()
            case .system:
                SystemView()
            case .projectDocs:
                // Legacy path from selectProjectDocs()
                if let projectName = appState.selectedProjectName {
                    ProjectDocsView(projectName: projectName, workingDirectory: appState.selectedProjectPath)
                } else {
                    ProjectsView()
                }
            }
        }
    }
}
