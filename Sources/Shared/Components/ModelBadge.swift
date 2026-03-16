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
            .accessibilityLabel("Model: \(displayName)")
    }

    private var displayName: String {
        if let option = ModelCatalog.option(for: model) {
            return option.label
        }
        if model.contains("haiku") { return "Haiku" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("opus") { return "Opus" }
        if model.contains("codex") { return "Codex" }
        return model
    }

    private var color: Color {
        if model.contains("haiku") { return .mint }
        if model.contains("sonnet") { return .indigo }
        if model.contains("opus") { return .orange }
        if model.contains("codex") { return .cyan }
        return .secondary
    }
}
