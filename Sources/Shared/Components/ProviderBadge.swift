import SwiftUI

struct ProviderBadge: View {
    @ObservedObject private var providerManager = ProviderManager.shared

    var body: some View {
        Text(providerManager.activeProviderBadge)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(4)
    }

    private var color: Color {
        switch providerManager.activeProvider?.identifier {
        case "claude-code": return .cyan
        case "anthropic-api": return .blue
        case "ollama": return .green
        default: return .secondary
        }
    }
}
