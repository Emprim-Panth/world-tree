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

            connectionTab
                .tabItem {
                    Label("Connection", systemImage: "network")
                }
        }
        .frame(width: 450, height: 300)
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
