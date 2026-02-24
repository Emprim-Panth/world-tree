import SwiftUI
import AppKit

/// TextEditor wrapper with custom keyboard handling and auto-growing height.
struct KeyboardHandlingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
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

        // Allow the text container to track the scroll view width so text wraps,
        // but let the text view grow vertically with content.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        // Calculate initial height
        DispatchQueue.main.async {
            context.coordinator.recalcHeight(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.recalcHeight(textView)
        }
        context.coordinator.onTabKey = onTabKey
        context.coordinator.onShiftTabKey = onShiftTabKey
        context.coordinator.onCmdReturnKey = onCmdReturnKey
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, contentHeight: $contentHeight)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var contentHeight: CGFloat
        var onTabKey: (() -> Bool)?
        var onShiftTabKey: (() -> Bool)?
        var onCmdReturnKey: (() -> Bool)?
        var onSubmit: (() -> Void)?

        init(text: Binding<String>, contentHeight: Binding<CGFloat>) {
            _text = text
            _contentHeight = contentHeight
        }

        func recalcHeight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            // Add vertical text container inset (top + bottom)
            let inset = textView.textContainerInset.height * 2
            let newHeight = usedRect.height + inset
            if abs(newHeight - contentHeight) > 1 {
                contentHeight = newHeight
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            recalcHeight(textView)
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
