import SwiftUI

// MARK: - PencilSettingsView

struct PencilSettingsView: View {
    @AppStorage("pencil.feature.enabled") private var featureEnabled = false
    @AppStorage("pencil.mcp.url") private var mcpURL = PencilMCPClient.defaultURL
    @ObservedObject private var pencil = PencilConnectionStore.shared

    @State private var urlInput = ""
    @State private var urlValidationError: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Pencil Integration") {
                Toggle("Enable Pencil canvas", isOn: $featureEnabled)
                    .onChange(of: featureEnabled) { _, enabled in
                        if enabled {
                            PencilConnectionStore.shared.startPolling()
                        } else {
                            PencilConnectionStore.shared.stopPolling()
                        }
                    }

                if featureEnabled {
                    LabeledContent("MCP Server URL") {
                        HStack {
                            TextField("http://localhost:4100", text: $urlInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 240)
                                .onAppear { urlInput = mcpURL }
                                .onChange(of: urlInput) { _, newValue in
                                    validateAndSaveURL(newValue)
                                }

                            if let error = urlValidationError {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                    .help(error)
                            }
                        }
                    }

                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(pencil.isConnected ? Color.green : Color.red)
                                .frame(width: 7, height: 7)
                            Text(pencil.isConnected ? "Connected" : "Offline")
                                .font(.system(size: 12))

                            if let error = pencil.lastError, !pencil.isConnected {
                                Text("· \(error)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    LabeledContent("") {
                        Button {
                            Task {
                                isTesting = true
                                await PencilConnectionStore.shared.refreshNow()
                                isTesting = false
                            }
                        } label: {
                            if isTesting {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini)
                                    Text("Testing…")
                                }
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .disabled(isTesting)
                    }
                }
            }

            if featureEnabled {
                Section("About") {
                    Text("World Tree connects to your running Pencil MCP server to display canvas state in the Command Center. Pencil must be running in VS Code or Cursor for the connection to work.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Link("Open Pencil.dev", destination: URL(string: "https://pencil.dev")!)
                        .font(.system(size: 11))
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func validateAndSaveURL(_ value: String) {
        guard let url = URL(string: value),
              url.scheme == "http" || url.scheme == "https",
              let host = url.host, !host.isEmpty else {
            urlValidationError = "Enter a valid HTTP URL (e.g. http://localhost:4100)"
            return
        }

        if let port = url.port, (port < 1024 || port > 65535) {
            urlValidationError = "Port must be between 1024 and 65535"
            return
        }

        urlValidationError = nil
        mcpURL = value
        Task { await PencilConnectionStore.shared.refreshNow() }
    }
}
