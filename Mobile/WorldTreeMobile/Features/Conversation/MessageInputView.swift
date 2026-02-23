import SwiftUI

/// Bottom-pinned message input bar.
///
/// - Multi-line TextField grows from 1 to 5 lines, then scrolls.
/// - Send button is disabled when text is empty (after trimming) or `isBusy` is true.
/// - Return key inserts a newline; the send button is the only submit action.
/// - Character count appears when the field is non-empty.
struct MessageInputView: View {
    @Binding var text: String
    /// Placeholder text — defaults to "Message…" but callers can supply the branch name.
    var placeholder: String = "Message…"
    let isBusy: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($isFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                    if !text.isEmpty {
                        Text("\(text.count)")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(text.count > 8_000 ? Color.red : Color.secondary)
                            .padding(.trailing, 8)
                            .padding(.bottom, 4)
                    }
                }
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))

                if isBusy {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.red)
                    }
                } else {
                    Button(action: sendAndDismiss) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                            .animation(.easeInOut(duration: 0.15), value: canSend)
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(uiColor: .systemBackground))
        }
        .frame(maxWidth: DesignTokens.Layout.inputBarMaxWidth)
    }

    private func sendAndDismiss() {
        isFocused = false
        onSend()
    }
}
