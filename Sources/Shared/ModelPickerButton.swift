import SwiftUI

/// Toolbar button that shows the active model and lets you switch instantly.
/// Reads/writes the same UserDefaults key that ClaudeCodeProvider uses,
/// so the next chat message immediately uses the new model.
struct ModelPickerButton: View {
    @AppStorage("defaultModel") private var defaultModel = CortanaConstants.defaultModel

    private struct ModelOption {
        let id: String
        let label: String
        let badge: String
        let description: String
    }

    private let models: [ModelOption] = [
        ModelOption(id: "claude-sonnet-4-5-20250929", label: "Sonnet",  badge: "S", description: "Balanced — fast, capable, default"),
        ModelOption(id: "claude-opus-4-6",            label: "Opus",    badge: "O", description: "Deep — complex reasoning, slower"),
        ModelOption(id: "claude-haiku-4-5-20251001",  label: "Haiku",   badge: "H", description: "Fast — quick tasks, lightest"),
    ]

    private var active: ModelOption {
        models.first { $0.id == defaultModel } ?? models[0]
    }

    var body: some View {
        Menu {
            ForEach(models, id: \.id) { model in
                Button {
                    defaultModel = model.id
                } label: {
                    HStack {
                        Text(model.label)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(model.description)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.id == defaultModel)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption)
                Text(active.label)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12))
            .cornerRadius(5)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Active model: \(active.label) — click to switch")
    }
}
