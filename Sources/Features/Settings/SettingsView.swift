import SwiftUI
import Security
import CryptoKit

struct SettingsView: View {
    @AppStorage(AppConstants.databasePathKey) private var databasePath = AppConstants.databasePath
    @AppStorage("daemonSocketPath") private var daemonSocketPath = AppConstants.daemonSocketPath
    @AppStorage(AppConstants.defaultModelKey) private var defaultModel = AppConstants.defaultModel
    @AppStorage(AppConstants.contextDepthKey) private var contextDepth = AppConstants.defaultContextDepth
    @StateObject private var providerManager = ProviderManager.shared
    @StateObject private var server = WorldTreeServer.shared

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

            CortanaControlView()
                .tabItem {
                    Label("Cortana", systemImage: "brain.head.profile")
                }

            serverTab
                .tabItem {
                    Label("Server", systemImage: "server.rack")
                }

            remoteTab
                .tabItem {
                    Label("Remote", systemImage: "link.icloud")
                }

            connectionTab
                .tabItem {
                    Label("Connection", systemImage: "network")
                }

            voiceTab
                .tabItem {
                    Label("Voice", systemImage: "speaker.wave.2")
                }

            pencilTab
                .tabItem {
                    Label("Pencil", systemImage: "pencil.circle")
                }
        }
        .frame(width: 520)
        .frame(minHeight: 400)
    }

    // MARK: - Provider

    private var providerTab: some View {
        Form {
            Section("Active Provider") {
                ForEach(providerManager.selectableProviders, id: \.identifier) { provider in
                    HStack(spacing: 10) {
                        // Selection radio
                        Image(systemName: provider.identifier == providerManager.selectedProviderId
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(provider.identifier == providerManager.selectedProviderId
                                             ? .blue : .secondary)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Select \(provider.displayName)")
                            .accessibilityValue(provider.identifier == providerManager.selectedProviderId ? "selected" : "not selected")
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
            .accessibilityLabel("Health: \(health?.statusLabel ?? "Unknown")")
    }

    private func providerDescription(_ identifier: String) -> String {
        switch identifier {
        case "claude-code":
            return "CLI backend using Max subscription. Free, full tools + session resume."
        case "anthropic-api":
            return "Direct API with managed context. Requires API credits."
        case "codex-cli":
            return "OpenAI Codex via the local CLI. Uses your OpenAI key or Codex login."
        case "ollama":
            return "Local models via Ollama. Free, private, not yet implemented."
        case "remote-canvas":
            return "Routes messages to a remote World Tree host."
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
            .accessibilityLabel("\(label): \(active ? "supported" : "not supported")")
    }

    // MARK: - General

    private var appState = AppState.shared
    @AppStorage(AppConstants.globalHotKeyEnabledKey) private var globalHotKeyEnabled = true

    private var modelSelectionBinding: Binding<String> {
        Binding(
            get: { defaultModel },
            set: { providerManager.selectModel($0) }
        )
    }

    private var generalTab: some View {
        @Bindable var appState = appState
        return Form {
            Section("Default Model") {
                Picker("Model", selection: modelSelectionBinding) {
                    ForEach(providerManager.availableModelOptions, id: \.id) { model in
                        Text("\(model.label) (\(model.description))").tag(model.id)
                    }
                }

                Text("Selecting a model also switches to its provider. Current provider: \(providerManager.activeProviderName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Context") {
                Stepper("Messages on fork: \(contextDepth)", value: $contextDepth, in: 3...50)
            }

            Section("Global Hotkey") {
                Toggle(isOn: $globalHotKeyEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable ⌘⇧Space")
                            .fontWeight(.medium)
                        Text("Bring World Tree to the front from any app. Takes effect on next launch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: globalHotKeyEnabled) { _, enabled in
                    if enabled {
                        GlobalHotKey.shared.register()
                    } else {
                        GlobalHotKey.shared.unregister()
                    }
                }
            }

            Section("Build") {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
                LabeledContent("Version", value: "\(version) (build \(build))")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - API

    @State private var apiKeyInput = ""
    @State private var showAPIKey = false
    @State private var openAIKeyInput = ""
    @State private var showOpenAIKey = false
    @State private var anthropicKeychainPresent = false
    @State private var openAIKeychainPresent = false
    @AppStorage(AppConstants.extendedThinkingEnabledKey) private var extendedThinkingEnabled = false
    @AppStorage(AppConstants.fileWriteReviewEnabledKey) private var fileWriteReviewEnabled = false

    private func refreshKeyStatus() {
        anthropicKeychainPresent = ClaudeService.shared.isConfigured
        openAIKeychainPresent = OpenAIKeyStore.isConfigured
    }

    private var apiTab: some View {
        Form {
            Section("Anthropic API Key") {
                let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil

                if envKey {
                    Label("API key loaded from environment", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if anthropicKeychainPresent {
                    Label("API key loaded from Keychain", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    Button("Clear Keychain Key") {
                        ClaudeService.shared.setAPIKey("")
                        refreshProvidersAfterCredentialChange()
                        refreshKeyStatus()
                    }
                    .foregroundStyle(.red)
                } else if !apiKeyInput.isEmpty {
                    Label("Unsaved key — click Save to store", systemImage: "key")
                        .foregroundStyle(.secondary)
                } else {
                    Label("No API key configured", systemImage: "xmark.circle")
                        .foregroundStyle(.orange)
                }

                Divider()

                HStack {
                    if showAPIKey {
                        TextField("sk-ant-...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                            .font(.caption)
                    } else {
                        SecureField("sk-ant-...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                            .font(.caption)
                    }

                    Button(action: { showAPIKey.toggle() }) {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showAPIKey ? "Hide API key" : "Show API key")
                }

                Button("Save to Keychain") {
                    ClaudeService.shared.setAPIKey(apiKeyInput)
                    apiKeyInput = ""
                    refreshProvidersAfterCredentialChange()
                    refreshKeyStatus()
                }
                .disabled(apiKeyInput.isEmpty)

                Text("Get your API key from: https://console.anthropic.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI API Key (Codex)") {
                if OpenAIKeyStore.hasEnvironmentKey {
                    Label("API key loaded from environment", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if openAIKeychainPresent {
                    Label("API key loaded from Keychain", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    Button("Clear Keychain Key") {
                        OpenAIKeyStore.clearAPIKey()
                        refreshProvidersAfterCredentialChange()
                        refreshKeyStatus()
                    }
                    .foregroundStyle(.red)
                } else if !openAIKeyInput.isEmpty {
                    Label("Unsaved key — click Save to store", systemImage: "key")
                        .foregroundStyle(.secondary)
                } else {
                    Label("No API key configured", systemImage: "xmark.circle")
                        .foregroundStyle(.orange)
                }

                Divider()

                HStack {
                    if showOpenAIKey {
                        TextField("sk-...", text: $openAIKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                            .font(.caption)
                    } else {
                        SecureField("sk-...", text: $openAIKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                            .font(.caption)
                    }

                    Button(action: { showOpenAIKey.toggle() }) {
                        Image(systemName: showOpenAIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showOpenAIKey ? "Hide OpenAI API key" : "Show OpenAI API key")
                }

                Button("Save to Keychain") {
                    OpenAIKeyStore.saveAPIKey(openAIKeyInput)
                    openAIKeyInput = ""
                    refreshProvidersAfterCredentialChange()
                    refreshKeyStatus()
                }
                .disabled(openAIKeyInput.isEmpty)

                Text("Used by Codex CLI when World Tree is launched outside your shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Intelligence") {
                Toggle(isOn: $extendedThinkingEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Extended Thinking")
                            .fontWeight(.medium)
                        Text("Claude reasons internally before responding. Improves quality on complex tasks. Uses more tokens (32K budget).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $fileWriteReviewEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Review File Writes")
                            .fontWeight(.medium)
                        Text("Show a diff and require your approval before any file is written or edited. Adds one step but gives full control over every change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refreshKeyStatus() }
    }

    // MARK: - Server

    @AppStorage(WorldTreeServer.enabledKey) private var serverEnabled = false
    @AppStorage(WorldTreeServer.tokenKey) private var serverToken = ""
    @AppStorage(WorldTreeServer.bonjourEnabledKey) private var bonjourEnabled = true
    @AppStorage(PluginServer.enabledKey) private var pluginEnabled = true
    @StateObject private var pluginServer = PluginServer.shared
    @State private var tokenInput = ""
    @State private var showToken = false
    @State private var showRegenConfirm = false
    @State private var tokenCopied = false

    private var serverTab: some View {
        Form {
            Section("Plugin Server (Cortana)") {
                Toggle("Enable plugin server (port \(PluginServer.port))", isOn: $pluginEnabled)
                    .onChange(of: pluginEnabled) { _, enabled in
                        handlePluginServerToggle(enabled)
                    }

                HStack(spacing: 6) {
                    Circle()
                        .fill(pluginServer.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(pluginServer.isRunning
                         ? "Running — MCP tools exposed to Friday"
                         : (pluginServer.lastError ?? "Stopped"))
                        .font(.caption)
                        .foregroundStyle(pluginServer.isRunning ? .primary : .secondary)
                }
                .accessibilityElement(children: .combine)

                if pluginServer.isRunning {
                    Text("~/.cortana/state/plugins/world-tree.json")
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("World Tree Hub") {
                Toggle("Enable server (port \(WorldTreeServer.port))", isOn: $serverEnabled)
                    .onChange(of: serverEnabled) { _, enabled in
                        if enabled { server.start() } else { server.stop() }
                    }

                HStack(spacing: 6) {
                    Circle()
                        .fill(server.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(server.isRunning
                         ? "Running — \(server.requestCount) requests"
                         : (server.lastError ?? "Stopped"))
                        .font(.caption)
                        .foregroundStyle(server.isRunning ? .primary : .secondary)
                }
                .accessibilityElement(children: .combine)

                Toggle("Advertise via Bonjour (_worldtree._tcp.)", isOn: $bonjourEnabled)
                    .font(.callout)

                if let serviceName = server.bonjourServiceName {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text(serviceName)
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Auth Token") {
                Text("Clients must send this token to authenticate. Enter a passphrase to generate a deterministic token, or regenerate a random one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Current token display
                HStack(spacing: 8) {
                    Group {
                        if showToken {
                            Text(serverToken.isEmpty ? "No token set" : serverToken)
                                .monospaced()
                                .font(.caption)
                                .foregroundStyle(serverToken.isEmpty ? .secondary : .primary)
                                .textSelection(.enabled)
                        } else {
                            Text(serverToken.isEmpty ? "No token set" : String(repeating: "•", count: min(serverToken.count, 32)))
                                .monospaced()
                                .font(.caption)
                                .foregroundStyle(serverToken.isEmpty ? .secondary : .primary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: { showToken.toggle() }) {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showToken ? "Hide token" : "Show token")

                    if !serverToken.isEmpty {
                        Button(tokenCopied ? "Copied!" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(serverToken, forType: .string)
                            tokenCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { tokenCopied = false }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(tokenCopied ? .green : .primary)
                    }
                }
                .padding(.vertical, 2)

                Divider()

                // Generate from passphrase
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set from passphrase")
                        .font(.callout)
                    HStack {
                        if showToken {
                            TextField("Passphrase", text: $tokenInput)
                                .textFieldStyle(.roundedBorder)
                                .monospaced()
                                .font(.caption)
                        } else {
                            SecureField("Passphrase", text: $tokenInput)
                                .textFieldStyle(.roundedBorder)
                                .monospaced()
                                .font(.caption)
                        }
                        Button("Generate") {
                            generateFromPhrase()
                        }
                        .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("SHA-256 hash passphrase into a 32-char hex token")
                    }
                    Text("Derives a reproducible hex token from your phrase — same phrase always gives the same token.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Random Token")
                            .font(.callout)
                        Text("Generates a new cryptographic random token and disconnects all mobile clients.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Regenerate…") {
                        showRegenConfirm = true
                    }
                    .foregroundStyle(.orange)
                    .confirmationDialog(
                        "Regenerate Server Token?",
                        isPresented: $showRegenConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Regenerate Token", role: .destructive) {
                            regenerateToken()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will disconnect all active mobile clients immediately. They will need the new token to reconnect.")
                    }
                }
            }

            Section("Remote Access (Mobile)") {
                if let hostname = server.ngrokHostname {
                    Label("Tunnel active", systemImage: "network")
                        .foregroundStyle(.green)
                        .font(.caption)

                    HStack(spacing: 8) {
                        Text(hostname)
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(hostname, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Text("Paste this hostname into World Tree Mobile → Settings → Remote Access.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Label("No ngrok tunnel detected", systemImage: "network.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("com.cortana.worldtree-tunnel starts automatically at login.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Quick test") {
                Text(#"curl -H "x-worldtree-token: TOKEN" http://localhost:\#(WorldTreeServer.port)/health"#)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Remote Studio (MacBook client mode)

    @AppStorage(AppConstants.remoteEnabledKey) private var remoteEnabled = false
    @AppStorage(AppConstants.remoteURLKey) private var remoteURL = ""
    @AppStorage(AppConstants.remoteTokenKey) private var remoteToken = ""
    @State private var remoteURLInput = ""
    @State private var remoteTokenInput = ""
    @State private var showRemoteToken = false
    @State private var remoteHealthStatus = ""

    private var remoteTab: some View {
        Form {
            Section("Connect to Studio") {
                Text("When enabled, all messages are sent to your Mac Studio's World Tree hub. The UI is identical — tokens stream in real time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Connect to Remote Studio", isOn: $remoteEnabled)
                    .onChange(of: remoteEnabled) { _, enabled in
                        applyRemoteToggle(enabled)
                    }

                // Status dot
                HStack(spacing: 6) {
                    let isActive = providerManager.selectedProviderId == "remote-canvas"
                    Circle()
                        .fill(isActive ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(isActive ? "Active — routing to Studio" : "Inactive — local providers in use")
                        .font(.caption)
                        .foregroundStyle(isActive ? .primary : .secondary)
                }
            }

            Section("Studio URL") {
                if !remoteURL.isEmpty {
                    Text(remoteURL)
                        .font(.caption).monospaced()
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }

                HStack {
                    TextField("https://…ngrok-free.app  or  ws://192.168.x.x:5866",
                              text: $remoteURLInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption).monospaced()
                    Button("Save") {
                        let trimmed = remoteURLInput.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        remoteURL = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
                        remoteURLInput = ""
                        if remoteEnabled { applyRemoteToggle(true) }
                    }
                    .disabled(remoteURLInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Text("Paste the ngrok URL from Studio World Tree → Settings → Server.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Studio Token") {
                HStack {
                    if showRemoteToken {
                        TextField("x-worldtree-token", text: $remoteTokenInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption).monospaced()
                    } else {
                        SecureField("x-worldtree-token", text: $remoteTokenInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption).monospaced()
                    }
                    Button(action: { showRemoteToken.toggle() }) {
                        Image(systemName: showRemoteToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showRemoteToken ? "Hide token" : "Show token")
                    Button("Save") {
                        let trimmed = remoteTokenInput.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        remoteToken = trimmed
                        remoteTokenInput = ""
                        if remoteEnabled { applyRemoteToggle(true) }
                    }
                    .disabled(remoteTokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                HStack {
                    if !remoteToken.isEmpty {
                        Label("Token configured", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Label("No token set", systemImage: "xmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }

                    Spacer()

                    Button("Test Connection") {
                        Task { await testRemoteConnection() }
                    }
                    .disabled(remoteURL.isEmpty || remoteToken.isEmpty)
                    .font(.caption)
                }

                if !remoteHealthStatus.isEmpty {
                    Text(remoteHealthStatus)
                        .font(.caption)
                        .foregroundStyle(remoteHealthStatus.hasPrefix("✓") ? .green : .red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Token Regeneration (TASK-027)

    /// Derive a 32-char hex token by SHA-256 hashing the user's passphrase.
    private func generateFromPhrase() {
        let phrase = tokenInput.trimmingCharacters(in: .whitespaces)
        guard !phrase.isEmpty else { return }
        let digest = SHA256.hash(data: Data(phrase.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        applyToken(hex)
        tokenInput = ""
    }

    /// Generate a new cryptographically-random 32-char hex token, persist it, and
    /// disconnect all active WebSocket clients so they must re-authenticate.
    private func regenerateToken() {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let newToken = bytes.map { String(format: "%02x", $0) }.joined()
        applyToken(newToken)

        // Disconnect all active WebSocket clients immediately.
        for client in server.webSocketClients.values {
            client.wsConnection?.sendCloseAndDisconnect(code: 1008, reason: "Token regenerated — reconnect with new token")
        }

        wtLog("[Settings] Server token regenerated — \(server.webSocketClients.count) client(s) disconnected")
    }

    /// Write the new token via @AppStorage (so SwiftUI re-renders immediately)
    /// and auto-copy it to the clipboard.
    private func applyToken(_ token: String) {
        serverToken = token
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        tokenCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { tokenCopied = false }
    }

    private func applyRemoteToggle(_ enabled: Bool) {
        if enabled {
            guard !remoteURL.isEmpty, !remoteToken.isEmpty,
                  let url = URL(string: remoteURL) else {
                // Can't enable without URL + token — silently revert
                remoteEnabled = false
                return
            }
            UserDefaults.standard.set(true, forKey: AppConstants.remoteEnabledKey)
            providerManager.enableRemoteProvider(url: url, token: remoteToken)
        } else {
            UserDefaults.standard.set(false, forKey: AppConstants.remoteEnabledKey)
            providerManager.disableRemoteProvider()
        }
    }

    private func testRemoteConnection() async {
        guard let url = URL(string: remoteURL) else {
            remoteHealthStatus = "✗ Invalid URL"
            return
        }
        remoteHealthStatus = "Testing…"
        let provider = RemoteWorldTreeProvider(serverURL: url, token: remoteToken)
        let health = await provider.checkHealth()
        switch health {
        case .available:
            remoteHealthStatus = "✓ Connected — Studio is online"
        case .degraded(let reason):
            remoteHealthStatus = "⚠ Degraded: \(reason)"
        case .unavailable(let reason):
            remoteHealthStatus = "✗ Unreachable: \(reason)"
        }
    }

    private func refreshProvidersAfterCredentialChange() {
        providerManager.reloadProviders()
        Task {
            await providerManager.refreshHealth()
        }
    }

    private func handlePluginServerToggle(_ enabled: Bool) {
        if enabled {
            pluginServer.start()
        } else {
            pluginServer.stop()
        }

        let codexSyncEnabled = UserDefaults.standard.object(forKey: AppConstants.codexMCPSyncEnabledKey) as? Bool ?? true
        Task {
            if codexSyncEnabled {
                await CodexMCPConfigManager.shared.syncFromClaudeAsync(includeWorldTree: enabled)
            } else if !enabled {
                await CodexMCPConfigManager.shared.removeWorldTreeRegistration()
            }
        }
    }

    // MARK: - Voice

    @AppStorage(AppConstants.voiceAutoSpeakKey) private var voiceAutoSpeak = false
    @AppStorage(AppConstants.voiceSpeedKey) private var voiceSpeed = 1.0
    @AppStorage(AppConstants.voicePitchKey) private var voicePitch = 1.0

    private var voiceTab: some View {
        Form {
            Section("Text-to-Speech") {
                Toggle("Auto-speak responses", isOn: $voiceAutoSpeak)

                Text("When enabled, \(LocalAgentIdentity.name) reads responses aloud using system TTS. You can also right-click any response and choose \"Read Aloud\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Voice Settings") {
                HStack {
                    Text("Speed")
                    Slider(value: $voiceSpeed, in: 0.5...2.0, step: 0.1)
                    Text(String(format: "%.1fx", voiceSpeed))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 32)
                }

                HStack {
                    Text("Pitch")
                    Slider(value: $voicePitch, in: 0.5...2.0, step: 0.1)
                    Text(String(format: "%.1fx", voicePitch))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 32)
                }

                Button("Reset to Default") {
                    voiceSpeed = 1.0
                    voicePitch = 1.0
                }
                .controlSize(.small)
                .foregroundStyle(.secondary)
            }

            Section("Test") {
                Button("Speak Test") {
                    Task {
                        let options = SpeechOptions(speed: voiceSpeed, pitch: voicePitch)
                        try? await VoiceService.shared.speak(
                            "I'm \(LocalAgentIdentity.name). Systems are nominal.",
                            options: options
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Connection

    @AppStorage(AppConstants.daemonChannelEnabledKey) private var daemonEnabled = true
    @StateObject private var daemonService = DaemonService.shared

    private var connectionTab: some View {
        Form {
            Section("Daemon Channel (Cortana)") {
                Toggle("Route messages through daemon", isOn: $daemonEnabled)

                HStack(spacing: 6) {
                    Circle()
                        .fill(daemonService.isConnected ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(daemonService.isConnected
                         ? "Connected — \(AppConstants.daemonAPIURL)"
                         : "Not connected — daemon not running")
                        .font(.caption)
                        .foregroundStyle(daemonService.isConnected ? .primary : .secondary)
                }
                .accessibilityElement(children: .combine)

                Text(daemonEnabled && daemonService.isConnected
                     ? "World Tree → Cortana (memory + identity)"
                     : "Direct to provider (no daemon context)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Database") {
                HStack {
                    TextField("Path", text: $databasePath)
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                        .font(.caption)

                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.title = "Select Database File"
                        panel.allowedContentTypes = []
                        panel.allowsOtherFileTypes = true
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            databasePath = url.path
                        }
                    }
                    .controlSize(.small)
                }

                let exists = FileManager.default.fileExists(atPath: databasePath)
                HStack {
                    Label(
                        exists ? "Database found" : "Database not found",
                        systemImage: exists ? "checkmark.circle" : "xmark.circle"
                    )
                    .foregroundStyle(exists ? .green : .red)
                    .font(.caption)

                    Spacer()

                    if databasePath != AppConstants.databasePath {
                        Button("Reset to Default") {
                            databasePath = AppConstants.databasePath
                        }
                        .controlSize(.mini)
                        .foregroundStyle(.secondary)
                    }
                }

                Text("Change takes effect on next app launch.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

    // MARK: - Pencil Tab

    private var pencilTab: some View {
        PencilSettingsView()
    }
}
