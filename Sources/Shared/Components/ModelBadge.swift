import SwiftUI

struct ModelBadge: View {
    let model: String

    var body: some View {
        Text(displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(4)
    }

    private var displayName: String {
        if model.contains("haiku") { return "Haiku" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("opus") { return "Opus" }
        return model
    }

    private var color: Color {
        if model.contains("haiku") { return .mint }
        if model.contains("sonnet") { return .indigo }
        if model.contains("opus") { return .orange }
        return .secondary
    }
}
