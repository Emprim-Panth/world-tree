import SwiftUI

// MARK: - Hex Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Design Tokens

enum DesignTokens {

    // MARK: - Color

    enum Color {
        /// #0D1B2A — deepest background
        static let brandMidnight = SwiftUI.Color(hex: "0D1B2A")
        /// #141E2D — void background
        static let brandVoid = SwiftUI.Color(hex: "141E2D")
        /// #1E2D40 — elevated surface
        static let brandSurface = SwiftUI.Color(hex: "1E2D40")
        /// #C9A84C — accent gold
        static let brandGold = SwiftUI.Color(hex: "C9A84C")
        /// #8BA0B8 — muted secondary text
        static let brandAsh = SwiftUI.Color(hex: "8BA0B8")
        /// #E8E0D0 — primary foreground
        static let brandParchment = SwiftUI.Color(hex: "E8E0D0")
        /// #3D4F63 — border / bark
        static let brandBark = SwiftUI.Color(hex: "3D4F63")
        /// #2A1F14 — assistant bubble background (root)
        static let brandRoot = SwiftUI.Color(hex: "2A1F14")
    }

    // MARK: - Typography

    enum Typography {
        static let treeName = SwiftUI.Font.system(size: 15, weight: .medium)
        static let branchName = SwiftUI.Font.system(size: 14, weight: .regular)
        static let metaLabel = SwiftUI.Font.system(size: 12, weight: .regular)
        static let messageiPad = SwiftUI.Font.system(size: 16)
        static let statusBadge = SwiftUI.Font.system(size: 11, weight: .medium)
    }

    // MARK: - Spacing

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: - CornerRadius

    enum CornerRadius {
        static let bubble: CGFloat = 18
        static let badge: CGFloat = 6
        static let card: CGFloat = 10
    }

    // MARK: - Layout

    enum Layout {
        static let sidebarWidth: CGFloat = 260
        static let contentColumnWidth: CGFloat = 280
        static let userBubbleMaxWidthFraction: CGFloat = 0.65
        static let assistantBubbleMaxWidthFraction: CGFloat = 0.75
        static let bubbleAbsoluteMaxWidth: CGFloat = 560
        static let inputBarMaxWidth: CGFloat = 680
    }
}
