import SwiftUI

struct SettingsView: View {
    @AppStorage(AppConstants.databasePathKey) private var databasePath = AppConstants.databasePath

    // Gateway
    @AppStorage("gatewayURL") private var gatewayURL = "http://127.0.0.1:4862"
    @AppStorage("gatewayToken") private var gatewayToken = ""

    // Context Server
    @AppStorage("contextServerPort") private var contextServerPort = 4863

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            gatewayTab
                .tabItem { Label("Gateway", systemImage: "network") }
        }
        .frame(minWidth: 480, minHeight: 300)
        .padding()
    }

    // MARK: — General

    private var generalTab: some View {
        Form {
            Section("Database") {
                LabeledContent("Path") {
                    TextField("Database path", text: $databasePath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                }
                Text("Shared SQLite database at ~/.cortana/claude-memory/conversations.db")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Context Server") {
                LabeledContent("Port") {
                    TextField("Port", value: $contextServerPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                Text("HTTP server on 127.0.0.1:\(contextServerPort) — used by Claude sessions to pull project context")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: — Gateway

    private var gatewayTab: some View {
        Form {
            Section("Ark Gateway") {
                LabeledContent("URL") {
                    TextField("http://127.0.0.1:4862", text: $gatewayURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
                LabeledContent("Token") {
                    SecureField("Auth token", text: $gatewayToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
                Text("Loaded automatically from ~/.cortana/ark-gateway.toml if left blank")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
