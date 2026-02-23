import SwiftUI

/// Width-constrained message bubble for the iPad detail column.
struct iPadMessageBubble: View {
    let message: Message
    let maxWidth: CGFloat
    let fontSize: Double

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: DesignTokens.Spacing.xxs) {
            // Role label above bubble
            Text(isUser ? "You" : "Assistant")
                .font(.caption)
                .foregroundStyle(DesignTokens.Color.brandAsh)
                .padding(.horizontal, DesignTokens.Spacing.xs)

            HStack {
                if isUser { Spacer(minLength: 0) }
                Text(message.content)
                    .font(.system(size: fontSize))
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                    .background(
                        isUser ? Color.blue : DesignTokens.Color.brandRoot,
                        in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.bubble)
                    )
                    .foregroundStyle(isUser ? Color.white : DesignTokens.Color.brandParchment)
                    .frame(maxWidth: maxWidth, alignment: isUser ? .trailing : .leading)
                if !isUser { Spacer(minLength: 0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}
