import SwiftUI

struct SettingsView: View {
    @AppStorage("databasePath") private var databasePath = CortanaConstants.dropboxDatabasePath
    @AppStorage("daemonSocketPath") private var daemonSocketPath = CortanaConstants.daemonSocketPath
    @AppStorage("defaultModel") private var defaultModel = CortanaConstants.defaultModel
    @AppStorage("contextDepth") private var contextDepth = CortanaConstants.defaultContextDepth

    var body: some View {
        TabView {
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
        .frame(width: 480, height: 350)
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
                    Text("Direct API mode active — tools execute locally with managed context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Set ANTHROPIC_API_KEY in your shell profile to enable direct API mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Falling back to Claude CLI (no tool persistence between messages).")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Mode") {
                let hasKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil

                HStack {
                    Image(systemName: hasKey ? "bolt.fill" : "terminal")
                        .foregroundStyle(hasKey ? .blue : .secondary)
                    VStack(alignment: .leading) {
                        Text(hasKey ? "Direct API" : "CLI Fallback")
                            .fontWeight(.medium)
                        Text(hasKey
                            ? "Persistent tools, prompt caching, managed context"
                            : "Spawns claude CLI per message, no tool persistence"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
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
