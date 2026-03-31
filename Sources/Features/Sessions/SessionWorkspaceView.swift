import SwiftUI

/// Main session workspace — terminal + context chrome.
struct SessionWorkspaceView: View {
    var manager = SessionManager.shared
    @State private var isShowingNewSession = false
    @State private var showContextPanel = true

    var body: some View {
        Group {
            if manager.sessions.isEmpty {
                emptyState
            } else {
                activeWorkspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !manager.sessions.isEmpty {
                    Button {
                        showContextPanel.toggle()
                    } label: {
                        Image(systemName: showContextPanel ? "sidebar.trailing" : "sidebar.trailing")
                    }
                    .help(showContextPanel ? "Hide context panel" : "Show context panel")
                }

                Button { isShowingNewSession = true } label: {
                    Label("New Session", systemImage: "plus.rectangle")
                }
            }
        }
        .sheet(isPresented: $isShowingNewSession) {
            NewSessionSheet()
        }
        .onAppear { HookRouter.shared.startPolling() }
        .onDisappear { HookRouter.shared.stopPolling() }
        .background { sessionKeyboardShortcuts }
    }

    // MARK: - Active Workspace

    private var activeWorkspace: some View {
        VStack(spacing: 0) {
            alertBanner
            sessionTabBar

            GeometryReader { geo in
                HStack(spacing: 0) {
                    // Terminal (fills available space)
                    terminalArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Context panel (fixed width, collapsible)
                    if showContextPanel, let session = manager.activeSession {
                        Divider()
                        contextPanel(for: session)
                            .frame(width: min(320, geo.size.width * 0.3))
                    }
                }
            }

            cortanaBar
        }
    }

    // MARK: - Terminal Area

    private var terminalArea: some View {
        VStack(spacing: 0) {
            if let session = manager.activeSession {
                TerminalSessionView(
                    sessionID: session.id,
                    executable: manager.claudeExecutable,
                    arguments: session.claudeArguments,
                    workingDirectory: session.projectPath,
                    onProcessExited: { code in
                        manager.sessionExited(id: session.id, exitCode: code)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                OutputRailView(sessionID: session.claudeSessionID)
            }
        }
    }

    // MARK: - Tab Bar

    private var sessionTabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(manager.sessions) { session in
                        sessionTab(session)
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer()
        }
        .frame(height: 30)
        .background(Palette.cardBackground.opacity(0.6))
    }

    private func sessionTab(_ session: SessionManager.ManagedSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.state == .running ? Palette.success :
                      session.state == .crashed ? Palette.error : Palette.neutral)
                .frame(width: 7, height: 7)

            Text(session.project)
                .font(.system(size: 11, weight: session.id == manager.activeSessionID ? .semibold : .regular))
                .lineLimit(1)

            if manager.sessions.count > 1 {
                Button {
                    manager.removeSession(id: session.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 7))
                }
                .buttonStyle(.plain)
                .opacity(0.4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(session.id == manager.activeSessionID ?
                      Palette.cardBackground : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { manager.switchTo(id: session.id) }
    }

    // MARK: - Context Panel

    private func contextPanel(for session: SessionManager.ManagedSession) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                if session.isDispatch {
                    AgentProgressView(session: session)
                        .padding(8)
                }
                SessionContextPanel(session: session)
            }
        }
        .background(Palette.cardBackground.opacity(0.15))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "terminal.fill")
                .font(.system(size: 56))
                .foregroundStyle(Palette.cortana.opacity(0.3))

            VStack(spacing: 6) {
                Text("Sessions")
                    .font(.title2.bold())
                Text("Embedded Claude Code workspaces with live project context")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Button {
                isShowingNewSession = true
            } label: {
                Label("New Session", systemImage: "plus.rectangle")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Alert Banner

    @ViewBuilder
    private var alertBanner: some View {
        if let alert = crossSessionAlert {
            HStack(spacing: 8) {
                Image(systemName: "shield.checkered")
                    .foregroundStyle(Palette.cortana)
                Text(alert)
                    .font(.system(size: 10))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.cortana.opacity(0.08))
        }
    }

    private var crossSessionAlert: String? {
        let running = manager.sessions.filter { $0.state == .running }
        var projects: [String: Int] = [:]
        for s in running { projects[s.project, default: 0] += 1 }
        if let conflict = projects.first(where: { $0.value > 1 }) {
            return "\(conflict.value) sessions targeting \(conflict.key) — file conflicts possible"
        }
        if running.count >= 5 {
            return "\(running.count) active sessions — monitoring memory pressure"
        }
        return nil
    }

    // MARK: - Cortana Bar

    private var cortanaBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 9))
                .foregroundStyle(Palette.cortana)

            Text("\(manager.sessions.filter(\.isActive).count) active")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)

            if SystemHealthStore.shared.lastCheckDate != nil {
                Circle()
                    .fill(SystemHealthStore.shared.overallStatus == .healthy ? Palette.success : Palette.warning)
                    .frame(width: 5, height: 5)
            }

            Spacer()
        }
        .frame(height: 24)
        .padding(.horizontal, 12)
        .background(Palette.cardBackground.opacity(0.5))
    }

    // MARK: - Keyboard Shortcuts

    @ViewBuilder
    private var sessionKeyboardShortcuts: some View {
        Button("") { switchToSession(0) }.keyboardShortcut("1", modifiers: .command).hidden()
        Button("") { switchToSession(1) }.keyboardShortcut("2", modifiers: .command).hidden()
        Button("") { switchToSession(2) }.keyboardShortcut("3", modifiers: .command).hidden()
        Button("") { switchToSession(3) }.keyboardShortcut("4", modifiers: .command).hidden()
        Button("") { isShowingNewSession = true }.keyboardShortcut("t", modifiers: .command).hidden()
    }

    private func switchToSession(_ index: Int) {
        guard index < manager.sessions.count else { return }
        manager.switchTo(id: manager.sessions[index].id)
    }
}
