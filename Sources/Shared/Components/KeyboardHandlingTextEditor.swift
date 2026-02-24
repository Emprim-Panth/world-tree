import SwiftUI
import AppKit

/// TextEditor wrapper with custom keyboard handling.
/// Reports its needed height via `onHeightChange` so the parent can drive
/// an explicit `.frame(height:)` — the only reliable way to size an
/// NSScrollView inside SwiftUI without it filling all available space.
struct KeyboardHandlingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onTabKey: (() -> Bool)?
    var onShiftTabKey: (() -> Bool)?
    var onCmdReturnKey: (() -> Bool)?
    var onSubmit: (() -> Void)?
    /// Called whenever content height changes. Parent clamps and stores in @State.
    var onHeightChange: ((CGFloat) -> Void)?

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

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            // Re-measure after programmatic update (e.g. clear after submit)
            let coordinator = context.coordinator
            DispatchQueue.main.async { coordinator.reportHeight(from: textView) }
        }
        context.coordinator.onTabKey = onTabKey
        context.coordinator.onShiftTabKey = onShiftTabKey
        context.coordinator.onCmdReturnKey = onCmdReturnKey
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onHeightChange = onHeightChange
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
        var onHeightChange: ((CGFloat) -> Void)?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            reportHeight(from: textView)
        }

        /// Compute the NSTextView's natural content height and forward it to the parent.
        /// Minimum 44 pt (≈ 2 lines) so the box never collapses below a comfortable size.
        func reportHeight(from textView: NSTextView) {
            guard let container = textView.textContainer,
                  let manager = textView.layoutManager else { return }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container).height
            let inset = textView.textContainerInset
            let natural = used + inset.height * 2 + 4
            onHeightChange?(max(44, natural))
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                if let handler = onTabKey, handler() { return true }
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                if let handler = onShiftTabKey, handler() { return true }
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.command) {
                    if let handler = onCmdReturnKey, handler() { return true }
                } else {
                    onSubmit?()
                    return true
                }
            }
            return false
        }
    }
}
