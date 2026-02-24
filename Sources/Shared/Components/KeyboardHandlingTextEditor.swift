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
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // Allow the text view to resize vertically with content so
        // sizeThatFits can report the natural line height to SwiftUI.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false

        return scrollView
    }

    /// Reports content height to SwiftUI so the enclosing frame can size itself.
    /// Called each layout pass; the parent ZStack caps this at maxHeight: 200.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = scrollView.documentView as? NSTextView,
              let container = textView.textContainer,
              let manager = textView.layoutManager else {
            return CGSize(width: proposal.width ?? 0, height: 36)
        }
        manager.ensureLayout(for: container)
        let usedHeight = manager.usedRect(for: container).height
        let inset = textView.textContainerInset
        let natural = usedHeight + inset.height * 2 + 4
        return CGSize(width: proposal.width ?? 0, height: max(36, natural))
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
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
