import SwiftUI

struct SettingsView: View {
    @AppStorage("databasePath") private var databasePath = CortanaConstants.dropboxDatabasePath
    @AppStorage("daemonSocketPath") private var daemonSocketPath = CortanaConstants.daemonSocketPath
    @AppStorage("defaultModel") private var defaultModel = CortanaConstants.defaultModel
    @AppStorage("contextDepth") private var contextDepth = CortanaConstants.defaultContextDepth
    @ObservedObject private var providerManager = ProviderManager.shared

    var body: some View {
        TabView {
            providerTab
                .tabItem {
                    Label("Provider", systemImage: "cpu")
                }

            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            apiTab
                .tabItem {
                    Label("API", systemImage: "bolt.fill")
                }

            connectionTab
                .tabItem {
                    Label("Connection", systemImage: "network")
                }
        }
        .frame(width: 480, height: 400)
    }

    // MARK: - Provider

    private var providerTab: some View {
        Form {
            Section("Active Provider") {
                ForEach(providerManager.providers, id: \.identifier) { provider in
                    HStack(spacing: 10) {
                        // Selection radio
                        Image(systemName: provider.identifier == providerManager.selectedProviderId
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(provider.identifier == providerManager.selectedProviderId
                                             ? .blue : .secondary)
                            .onTapGesture {
                                providerManager.selectedProviderId = provider.identifier
                            }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(provider.displayName)
                                    .fontWeight(.medium)

                                // Health dot
                                healthDot(for: provider.identifier)
                            }

                            Text(providerDescription(provider.identifier))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        providerManager.selectedProviderId = provider.identifier
                    }
                }
            }

            Section("Capabilities") {
                if let provider = providerManager.activeProvider {
                    HStack(spacing: 8) {
                        capabilityTag("Streaming", active: provider.capabilities.contains(.streaming))
                        capabilityTag("Tools", active: provider.capabilities.contains(.toolExecution))
                        capabilityTag("Resume", active: provider.capabilities.contains(.sessionResume))
                        capabilityTag("Fork", active: provider.capabilities.contains(.sessionFork))
                    }
                    HStack(spacing: 8) {
                        capabilityTag("Cache", active: provider.capabilities.contains(.promptCaching))
                        capabilityTag("Cost", active: provider.capabilities.contains(.costTracking))
                        capabilityTag("Models", active: provider.capabilities.contains(.modelSelection))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await providerManager.refreshHealth()
        }
    }

    private func healthDot(for identifier: String) -> some View {
        let health = providerManager.healthStatus[identifier]
        let color: Color = {
            switch health {
            case .available: return .green
            case .degraded: return .yellow
            case .unavailable: return .red
            case .none: return .gray
            }
        }()

        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(health?.statusLabel ?? "Unknown")
    }

    private func providerDescription(_ identifier: String) -> String {
        switch identifier {
        case "claude-code":
            return "CLI backend using Max subscription. Free, full tools + session resume."
        case "anthropic-api":
            return "Direct API with managed context. Requires API credits."
        case "ollama":
            return "Local models via Ollama. Free, private, not yet implemented."
        default:
            return ""
        }
    }

    private func capabilityTag(_ label: String, active: Bool) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(active ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.1))
            .foregroundStyle(active ? .blue : .secondary)
            .cornerRadius(4)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Default Model") {
                Picker("Model", selection: $defaultModel) {
                    Text("Sonnet (Balanced)").tag("claude-sonnet-4-5-20250929")
                    Text("Opus (Deep)").tag("claude-opus-4-6")
                    Text("Haiku (Fast)").tag("claude-haiku-4-5-20251001")
                }
            }

            Section("Context") {
                Stepper("Messages on fork: \(contextDepth)", value: $contextDepth, in: 3...50)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - API

    private var apiTab: some View {
        Form {
            Section("Anthropic API") {
                let hasKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil

                Label(
                    hasKey ? "API key found in environment" : "No ANTHROPIC_API_KEY in environment",
                    systemImage: hasKey ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(hasKey ? .green : .orange)

                if hasKey {
                    Text("Direct API provider available. Switch to it in the Provider tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Set ANTHROPIC_API_KEY in your shell profile to enable the Direct API provider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Connection

    private var connectionTab: some View {
        Form {
            Section("Database") {
                TextField("Path", text: $databasePath)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
                    .font(.caption)

                let exists = FileManager.default.fileExists(atPath: databasePath)
                Label(
                    exists ? "Database found" : "Database not found",
                    systemImage: exists ? "checkmark.circle" : "xmark.circle"
                )
                .foregroundStyle(exists ? .green : .red)
                .font(.caption)
            }

            Section("Daemon") {
                TextField("Socket path", text: $daemonSocketPath)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
                    .font(.caption)

                let socketExists = FileManager.default.fileExists(atPath: daemonSocketPath)
                Label(
                    socketExists ? "Socket found" : "Daemon not running",
                    systemImage: socketExists ? "checkmark.circle" : "xmark.circle"
                )
                .foregroundStyle(socketExists ? .green : .red)
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
