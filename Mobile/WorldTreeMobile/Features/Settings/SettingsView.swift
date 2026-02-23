import SwiftUI

struct SettingsView: View {
    @AppStorage(Constants.UserDefaultsKeys.autoConnect) private var autoConnect = Constants.Defaults.autoConnect
    @AppStorage(Constants.UserDefaultsKeys.messageFontSize) private var messageFontSize = Constants.Defaults.messageFontSize
    @AppStorage(Constants.UserDefaultsKeys.remoteServerHost) private var remoteServerHost = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    Toggle("Auto-connect on launch", isOn: $autoConnect)
                }

                Section {
                    TextField("your-mac.ts.net", text: $remoteServerHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("Remote Access")
                } footer: {
                    if remoteServerHost.isEmpty {
                        Text("Tailscale hostname or IP used automatically when not on Wi-Fi.")
                    } else {
                        Label("Will connect via \(remoteServerHost) when off Wi-Fi.", systemImage: "lock.shield")
                            .foregroundStyle(.blue)
                    }
                }

                Section("Display") {
                    HStack {
                        Text("Message font size")
                        Spacer()
                        Stepper("\(Int(messageFontSize))pt", value: $messageFontSize, in: 12...24, step: 1)
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                    LabeledContent("Build", value: Bundle.main.buildNumber)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
