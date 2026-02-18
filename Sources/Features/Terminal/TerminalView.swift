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

    func makeNSView(context: Context) -> CapturingTerminalView {
        let tv = BranchTerminalManager.shared.getOrCreate(
            branchId: branchId,
            workingDirectory: workingDirectory
        )
        // Match Canvas dark theme — makes the terminal feel native rather than bolted-on
        tv.nativeBackgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        tv.nativeForegroundColor = NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1.0)
        tv.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        return tv
    }

    func updateNSView(_ nsView: CapturingTerminalView, context: Context) {
        // Make the terminal first responder whenever it (re)appears in the hierarchy.
        // Without this, the NSView is visible but never receives keyboard events —
        // the user can see output but can't type.
        DispatchQueue.main.async {
            if nsView.window != nil {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}
