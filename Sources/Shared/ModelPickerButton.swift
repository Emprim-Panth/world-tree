import SwiftUI

/// Toolbar button that shows the active model and lets you switch instantly.
/// Reads/writes the same UserDefaults key that ClaudeCodeProvider uses,
/// so the next chat message immediately uses the new model.
struct ModelPickerButton: View {
    @AppStorage(AppConstants.defaultModelKey) private var defaultModel = AppConstants.defaultModel
    @StateObject private var providerManager = ProviderManager.shared

    private var models: [ProviderModelOption] {
        providerManager.availableModelOptions
    }

    private var active: ProviderModelOption {
        models.first { $0.id == defaultModel }
            ?? ModelCatalog.option(for: defaultModel)
            ?? models[0]
    }

    var body: some View {
        Menu {
            ForEach(models, id: \.id) { model in
                Button {
                    providerManager.selectModel(model.id)
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
        .help("Active model: \(active.label) — click to switch model and provider")
    }
}
