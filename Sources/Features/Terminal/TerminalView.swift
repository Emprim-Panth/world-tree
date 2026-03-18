import SwiftUI
import SwiftTerm

// MARK: - TerminalFocusCoordinator

/// Shared coordinator for terminal NSViewRepresentables.
/// Installs a click gesture recognizer that claims keyboard focus on tap
/// without blocking SwiftTerm's own mouse handling (selection, scroll, etc.).
final class TerminalFocusCoordinator: NSObject {
    @objc func claimFocus(_ recognizer: NSClickGestureRecognizer) {
        guard let view = recognizer.view else { return }
        view.window?.makeFirstResponder(view)
    }
}

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

    func makeCoordinator() -> TerminalFocusCoordinator { TerminalFocusCoordinator() }

    func makeNSView(context: Context) -> CapturingTerminalView {
        let tv = BranchTerminalManager.shared.getOrCreate(
            branchId: branchId,
            workingDirectory: workingDirectory
        )
        // Match Canvas dark theme — makes the terminal feel native rather than bolted-on
        tv.nativeBackgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        tv.nativeForegroundColor = NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1.0)
        tv.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

        // Claim keyboard focus on click. delaysPrimaryMouseButtonEvents = false
        // lets SwiftTerm's own mouseDown (text selection, cursor placement) still fire.
        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(TerminalFocusCoordinator.claimFocus(_:))
        )
        click.delaysPrimaryMouseButtonEvents = false
        tv.addGestureRecognizer(click)

        return tv
    }

    func updateNSView(_ nsView: CapturingTerminalView, context: Context) {
        // Do NOT steal focus here — updateNSView fires on every SwiftUI render cycle.
    }
}

// MARK: - ProjectTerminalView

/// NSViewRepresentable for project-level terminals (wt-{projectName}).
/// Unlike branch terminals, these persist across branch switches within the same project.
/// Use .id(project) at the call site to swap terminals when switching projects.
struct ProjectTerminalView: NSViewRepresentable {
    let project: String
    let workingDirectory: String

    func makeCoordinator() -> TerminalFocusCoordinator { TerminalFocusCoordinator() }

    func makeNSView(context: Context) -> CapturingTerminalView {
        let tv = BranchTerminalManager.shared.getOrCreateProjectTerminal(
            project: project,
            workingDirectory: workingDirectory
        )
        tv.nativeBackgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        tv.nativeForegroundColor = NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1.0)
        tv.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(TerminalFocusCoordinator.claimFocus(_:))
        )
        click.delaysPrimaryMouseButtonEvents = false
        tv.addGestureRecognizer(click)

        return tv
    }

    func updateNSView(_ nsView: CapturingTerminalView, context: Context) {
        // Do NOT steal focus here — updateNSView fires on every render.
    }
}
