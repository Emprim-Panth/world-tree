import SwiftUI
import SwiftTerm

// MARK: - BranchTerminalView

/// NSViewRepresentable that pulls a persistent LocalProcessTerminalView from BranchTerminalManager.
///
/// The NSView (and its PTY process) is owned by BranchTerminalManager — NOT by this view.
/// When the SwiftUI view disappears and reappears, makeNSView returns the SAME instance,
/// so the shell session survives hide/show and branch switching.
///
/// Use .id(branchId) at the call site to force SwiftUI to recreate this wrapper when
/// switching to a different branch, ensuring makeNSView is called to pull the new terminal.
struct BranchTerminalView: NSViewRepresentable {
    let branchId: String
    let workingDirectory: String

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        BranchTerminalManager.shared.getOrCreate(
            branchId: branchId,
            workingDirectory: workingDirectory
        )
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // BranchTerminalManager owns the view and its lifecycle.
        // No updates from SwiftUI needed — the terminal is self-contained.
    }
}
