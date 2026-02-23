import SwiftUI

/// Shimmer placeholder shown while branch list is loading.
struct SkeletonBranchRow: View {
    @State private var opacity: Double = 0.3

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Icon placeholder
            RoundedRectangle(cornerRadius: 4)
                .frame(width: 16, height: 16)
                .foregroundStyle(DesignTokens.Color.brandBark)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                // Name placeholder
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.badge)
                    .frame(width: 140, height: 13)
                    .foregroundStyle(DesignTokens.Color.brandBark)

                // Subtitle placeholder
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.badge)
                    .frame(width: 80, height: 11)
                    .foregroundStyle(DesignTokens.Color.brandBark)
            }

            Spacer()

            // Message count placeholder
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.badge)
                .frame(width: 24, height: 13)
                .foregroundStyle(DesignTokens.Color.brandBark)
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .opacity(opacity)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 0.8)
                .repeatForever(autoreverses: true)
            ) {
                opacity = 0.7
            }
        }
    }
}
