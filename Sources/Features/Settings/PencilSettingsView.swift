import SwiftUI

// MARK: - PencilSettingsView

struct PencilSettingsView: View {
    @AppStorage("pencil.feature.enabled") private var featureEnabled = false
    @AppStorage(PencilMCPClient.binaryPathOverrideKey) private var binaryPathOverride = ""
    @ObservedObject private var pencil = PencilConnectionStore.shared

    @State private var discoveredPath: String? = nil
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
                    binaryRow
                    statusRow
                    testButton
                }
            }

            if featureEnabled {
                advancedSection
                aboutSection
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refreshDiscovery() }
    }

    // MARK: - Rows

    private var binaryRow: some View {
        LabeledContent("Pencil binary") {
            VStack(alignment: .trailing, spacing: 4) {
                if let path = discoveredPath {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 11))
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 11))
                        Text("Not found")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Text("Install Pencil.app or the VS Code extension")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var statusRow: some View {
        LabeledContent("Status") {
            HStack(spacing: 6) {
                Circle()
                    .fill(pencil.isConnected ? Color.green : Color.secondary)
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
    }

    private var testButton: some View {
        LabeledContent("") {
            Button {
                Task {
                    isTesting = true
                    refreshDiscovery()
                    await PencilConnectionStore.shared.refreshNow()
                    isTesting = false
                }
            } label: {
                if isTesting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Connecting…")
                    }
                } else {
                    Text("Connect")
                }
            }
            .disabled(isTesting || discoveredPath == nil)
        }
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        Section("Advanced") {
            LabeledContent("Binary path override") {
                TextField("Leave blank for auto-detect", text: $binaryPathOverride)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .font(.system(size: 11, design: .monospaced))
                    .onChange(of: binaryPathOverride) { _, _ in refreshDiscovery() }
            }
            Text("Override only if auto-detection finds the wrong binary. Path must point directly to the mcp-server executable inside the Pencil.app bundle or VS Code extension.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section("About") {
            Text("World Tree spawns the Pencil MCP binary as a subprocess and communicates via stdin/stdout. Works with Pencil.app (standalone), VS Code extension, and Cursor extension. No port configuration needed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Link("Open Pencil.dev", destination: URL(string: "https://pencil.dev")!)
                .font(.system(size: 11))
        }
    }

    // MARK: - Helpers

    private func refreshDiscovery() {
        Task {
            let path = await Task.detached { PencilMCPClient.discoverBinaryPath() }.value
            discoveredPath = path
        }
    }
}
