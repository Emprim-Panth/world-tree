import SwiftUI
import SwiftTerm

/// Wraps SwiftTerm's LocalProcessTerminalView in SwiftUI via NSViewRepresentable.
struct TerminalSessionView: NSViewRepresentable {
    let sessionID: UUID
    let executable: String
    let arguments: [String]
    let workingDirectory: String
    let onProcessExited: ((Int32) -> Void)?

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: .zero)
        tv.processDelegate = context.coordinator

        // Configure appearance
        tv.nativeBackgroundColor = NSColor.black
        tv.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Build environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let envStrings = env.map { "\($0.key)=\($0.value)" }

        tv.startProcess(
            executable: executable,
            args: arguments,
            environment: envStrings,
            execName: nil,
            currentDirectory: workingDirectory
        )

        return tv
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onProcessExited: onProcessExited)
    }

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onProcessExited: ((Int32) -> Void)?

        init(onProcessExited: ((Int32) -> Void)?) {
            self.onProcessExited = onProcessExited
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onProcessExited?(exitCode ?? -1)
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
