import SwiftUI
import AppKit

/// TextEditor wrapper with custom keyboard handling
struct KeyboardHandlingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onTabKey: (() -> Bool)?
    var onShiftTabKey: (() -> Bool)?
    var onCmdReturnKey: (() -> Bool)?
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.onTabKey = onTabKey
        context.coordinator.onShiftTabKey = onShiftTabKey
        context.coordinator.onCmdReturnKey = onCmdReturnKey
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onTabKey: (() -> Bool)?
        var onShiftTabKey: (() -> Bool)?
        var onCmdReturnKey: (() -> Bool)?
        var onSubmit: (() -> Void)?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Check for Tab
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                if let handler = onTabKey, handler() {
                    return true // Handled
                }
            }

            // Check for Shift+Tab
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                if let handler = onShiftTabKey, handler() {
                    return true
                }
            }

            // Check for Return (Submit)
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Check if Cmd is pressed
                if NSEvent.modifierFlags.contains(.command) {
                    if let handler = onCmdReturnKey, handler() {
                        return true
                    }
                } else {
                    // Regular return - submit
                    onSubmit?()
                    return true
                }
            }

            return false // Not handled, use default behavior
        }
    }
}
