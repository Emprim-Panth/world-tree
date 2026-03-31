import SwiftUI

/// Main session workspace -- terminal + context chrome.
struct SessionWorkspaceView: View {
    var manager = SessionManager.shared
    @State private var isShowingNewSession = false

    var body: some View {
        VStack(spacing: 0) {
            alertBanner
            mainSplitView
            cortanaBar
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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

    /// Hidden buttons that register Cmd+1..4 and Cmd+T keyboard shortcuts.
    @ViewBuilder
    private var sessionKeyboardShortcuts: some View {
        Button("") { switchToSession(0) }
            .keyboardShortcut("1", modifiers: .command)
            .hidden()
        Button("") { switchToSession(1) }
            .keyboardShortcut("2", modifiers: .command)
            .hidden()
        Button("") { switchToSession(2) }
            .keyboardShortcut("3", modifiers: .command)
            .hidden()
        Button("") { switchToSession(3) }
            .keyboardShortcut("4", modifiers: .command)
            .hidden()
        Button("") { isShowingNewSession = true }
            .keyboardShortcut("t", modifiers: .command)
            .hidden()
    }

    private func switchToSession(_ index: Int) {
        guard index < manager.sessions.count else { return }
        manager.switchTo(id: manager.sessions[index].id)
    }

    @ViewBuilder
    private var sessionContent: some View {
        if let session = manager.activeSession {
            VStack(spacing: 0) {
                sessionTabBar

                TerminalSessionView(
                    sessionID: session.id,
                    executable: manager.claudeExecutable,
                    arguments: session.claudeArguments,
                    workingDirectory: session.projectPath,
                    onProcessExited: { code in
                        manager.sessionExited(id: session.id, exitCode: code)
                    }
                )

                OutputRailView(sessionID: session.claudeSessionID)
            }
        } else {
            emptyState
        }
    }

    private var sessionTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(manager.sessions) { session in
                    sessionTab(session)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Palette.cardBackground)
    }

    private func sessionTab(_ session: SessionManager.ManagedSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.state == .running ? Palette.success :
                      session.state == .crashed ? Palette.error : Palette.neutral)
                .frame(width: 8, height: 8)

            Text(session.project)
                .font(.system(size: 11, weight: session.id == manager.activeSessionID ? .semibold : .regular))
                .lineLimit(1)

            Button {
                manager.removeSession(id: session.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8))
            }
            .buttonStyle(.plain)
            .opacity(0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(session.id == manager.activeSessionID ? Palette.cardBackground : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { manager.switchTo(id: session.id) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Active Sessions")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Start a new Claude Code session to begin working")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("New Session") { isShowingNewSession = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Alert Banner (TASK-94)

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
            .padding(8)
            .background(Palette.cortana.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
    }

    // MARK: - Main Split View

    private var mainSplitView: some View {
        HSplitView {
            sessionContent
                .frame(minWidth: 500)

            if let session = manager.activeSession {
                contextPanel(for: session)
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 400)
            }
        }
    }

    private func contextPanel(for session: SessionManager.ManagedSession) -> some View {
        VStack(spacing: 0) {
            if session.isDispatch {
                AgentProgressView(session: session)
                    .padding(8)
            }
            SessionContextPanel(session: session)
        }
    }

    // MARK: - Cross-Session Awareness (TASK-94)

    private var crossSessionAlert: String? {
        let running = manager.sessions.filter { $0.state == .running }
        // Check for project conflicts
        var projects: [String: Int] = [:]
        for s in running { projects[s.project, default: 0] += 1 }
        if let conflict = projects.first(where: { $0.value > 1 }) {
            return "\(conflict.value) sessions targeting \(conflict.key) — file conflicts possible"
        }
        // Check for high session count
        if running.count >= 5 {
            return "\(running.count) active sessions — monitoring memory pressure"
        }
        return nil
    }

    // MARK: - Cortana Presence Bar (TASK-96)

    private var cortanaBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 10))
                .foregroundStyle(Palette.cortana)

            Text("\(manager.sessions.filter(\.isActive).count) active")
                .font(.system(size: 9, weight: .medium))

            if SystemHealthStore.shared.lastCheckDate != nil {
                HStack(spacing: 3) {
                    Circle()
                        .fill(SystemHealthStore.shared.overallStatus == .healthy ? Palette.success : Palette.warning)
                        .frame(width: 5, height: 5)
                    Text("Health: \(SystemHealthStore.shared.overallStatus.rawValue)")
                        .font(.system(size: 9))
                }
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.cardBackground.opacity(0.8))
    }
}
