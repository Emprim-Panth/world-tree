import SwiftUI

/// Main session workspace -- terminal + context chrome.
struct SessionWorkspaceView: View {
    var manager = SessionManager.shared
    @State private var isShowingNewSession = false

    var body: some View {
        HSplitView {
            sessionContent
                .frame(minWidth: 500)

            if let session = manager.activeSession {
                SessionContextPanel(session: session)
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 400)
            }
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
}
