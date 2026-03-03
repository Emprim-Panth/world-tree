import SwiftUI
import Network

// MARK: - ServerPickerView

struct ServerPickerView: View {
    @Environment(ConnectionManager.self) private var connectionManager
    @AppStorage(Constants.UserDefaultsKeys.autoConnect) private var autoConnect = Constants.Defaults.autoConnect
    @State private var savedServers: [SavedServer] = []
    @State private var bonjourBrowser = BonjourBrowser()
    @State private var showAddServer = false
    @State private var addServerPrefill: AddServerPrefill? = nil
    @State private var showSettings = false
    @State private var isOnWifi = true
    @State private var didAutoConnect = false
    private let pathMonitor = NWPathMonitor()

    var body: some View {
        NavigationStack {
            List {
                nearbySection
                savedSection
            }
            .navigationTitle("World Tree")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { addServerPrefill = AddServerPrefill() }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(item: $addServerPrefill) { prefill in
                AddServerView(
                    prefillName: prefill.name,
                    prefillHost: prefill.host,
                    prefillPort: prefill.port
                ) { server in
                    savedServers.append(server)
                    persistServers()
                }
            }
            .onAppear {
                loadServers()
                bonjourBrowser.start()
                startNetworkMonitor()
            }
            .onDisappear {
                bonjourBrowser.stop()
                pathMonitor.cancel()
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var nearbySection: some View {
        if bonjourBrowser.isSearching || !bonjourBrowser.servers.isEmpty {
            Section {
                if bonjourBrowser.servers.isEmpty {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(bonjourBrowser.servers) { discovered in
                        NearbyServerRow(server: discovered) {
                            addServerPrefill = AddServerPrefill(
                                name: discovered.name,
                                host: discovered.host,
                                port: "\(discovered.port)"
                            )
                        }
                    }
                }
            } header: {
                Text("Nearby")
            }
        }
    }

    @ViewBuilder
    private var savedSection: some View {
        Section {
            if savedServers.isEmpty {
                ContentUnavailableView(
                    "No Saved Servers",
                    systemImage: "network.slash",
                    description: Text("Add your World Tree Mac address to connect.")
                )
            } else {
                ForEach(savedServers) { server in
                    ServerRow(server: server) {
                        connectTo(server)
                    }
                }
                .onDelete(perform: deleteServers)
            }
        } header: {
            if !savedServers.isEmpty {
                Text("Saved")
            }
        }
    }

    // MARK: - Actions

    private func connectTo(_ server: SavedServer) {
        Task { await connectionManager.connect(to: server) }
        persistLastServer(server)
        updateLastConnected(server)
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                self.isOnWifi = path.usesInterfaceType(.wifi)
                if !self.didAutoConnect {
                    self.didAutoConnect = true
                    self.autoConnectIfNeeded()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "worldtree.networkmonitor"))
    }

    private func autoConnectIfNeeded() {
        guard autoConnect, !connectionManager.suppressAutoConnect else { return }

        let remoteHost = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.remoteServerHost) ?? ""

        // Off Wi-Fi and remote server configured → connect to remote directly.
        if !isOnWifi && !remoteHost.isEmpty {
            let remote = SavedServer.manual(name: "Remote", host: remoteHost)
            Task { await connectionManager.connect(to: remote) }
            return
        }

        // On Wi-Fi (or no remote configured) → connect to last-used local server.
        guard let lastId = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastServerId),
              let server = savedServers.first(where: { $0.id == lastId })
        else { return }
        connectTo(server)
    }

    private func deleteServers(at offsets: IndexSet) {
        savedServers.remove(atOffsets: offsets)
        persistServers()
    }

    // MARK: - Persistence

    private func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: "savedServers"),
              let decoded = try? JSONDecoder().decode([SavedServer].self, from: data)
        else { return }
        savedServers = decoded
    }

    private func persistServers() {
        guard let data = try? JSONEncoder().encode(savedServers) else { return }
        UserDefaults.standard.set(data, forKey: "savedServers")
    }

    private func persistLastServer(_ server: SavedServer) {
        UserDefaults.standard.set(server.id, forKey: Constants.UserDefaultsKeys.lastServerId)
    }

    private func updateLastConnected(_ server: SavedServer) {
        guard let idx = savedServers.firstIndex(where: { $0.id == server.id }) else { return }
        savedServers[idx].lastConnectedAt = Date()
        persistServers()
    }
}

// MARK: - AddServerPrefill

/// Passed to the sheet to pre-fill AddServerView fields.
private struct AddServerPrefill: Identifiable {
    let id = UUID()
    var name: String = ""
    var host: String = ""
    var port: String = "\(Constants.Network.defaultPort)"
}

// MARK: - NearbyServerRow

private struct NearbyServerRow: View {
    let server: BonjourBrowser.DiscoveredServer
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.body)
                    Text(verbatim: "\(server.host):\(server.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Local", systemImage: "wifi")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
        .foregroundStyle(.primary)
    }
}

// MARK: - ServerRow

private struct ServerRow: View {
    let server: SavedServer
    let onConnect: () -> Void

    var body: some View {
        Button(action: onConnect) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.body)
                    Text(verbatim: "\(server.host):\(server.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let connectedAt = server.lastConnectedAt {
                        Text("Last connected \(connectedAt, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                serverTypeLabel
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var serverTypeLabel: some View {
        Label(
            server.isTailscale ? "Tailscale" : "Local",
            systemImage: server.isTailscale ? "lock.shield" : "wifi"
        )
        .labelStyle(.iconOnly)
        .foregroundStyle(server.isTailscale ? .blue : .green)
        .font(.caption)
    }
}

// MARK: - AddServerView

struct AddServerView: View {
    let onAdd: (SavedServer) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var host: String
    @State private var port: String

    init(
        prefillName: String = "",
        prefillHost: String = "",
        prefillPort: String = "\(Constants.Network.defaultPort)",
        onAdd: @escaping (SavedServer) -> Void
    ) {
        self.onAdd = onAdd
        self._name = State(initialValue: prefillName)
        self._host = State(initialValue: prefillHost)
        self._port = State(initialValue: prefillPort)
    }

    private var isTailscaleHost: Bool { host.hasSuffix(".ts.net") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Host (IP or hostname)", text: $host)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Server")
                } footer: {
                    if isTailscaleHost {
                        Label(
                            "Tailscale hostname detected. Make sure Tailscale is running on this device.",
                            systemImage: "lock.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.blue)
                    }
                }
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(name.isEmpty || host.isEmpty)
                }
            }
        }
    }

    private func add() {
        let portInt = Int(port) ?? Constants.Network.defaultPort
        let server = SavedServer.manual(name: name, host: host, port: portInt)
        onAdd(server)
        dismiss()
    }
}
