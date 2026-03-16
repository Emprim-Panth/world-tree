import SwiftUI

struct MCPToolsView: View {
    @State private var config = MCPConfigManager.shared
    @State private var selectedServer: MCPServerConfig?
    @State private var sourceText: String = ""
    @State private var isEditing = false
    @State private var showSaveConfirm = false
    @State private var saveError: String?
    @State private var parsedTools: [MCPToolInfo] = []
    private let splitLayoutThreshold: CGFloat = 980

    var body: some View {
        GeometryReader { proxy in
            Group {
                if proxy.size.width >= splitLayoutThreshold {
                    HSplitView {
                        serverList
                            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                        detailPane
                            .frame(minWidth: 360, maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 12) {
                        serverList
                            .frame(minHeight: 220, idealHeight: min(320, max(220, proxy.size.height * 0.32)))
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        detailPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: 500)
        .onAppear { config.reload() }
    }

    // MARK: - Server List

    private var serverList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MCP Servers")
                    .font(.headline)
                Spacer()
                Button {
                    config.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Reload settings.json")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if config.servers.isEmpty {
                ContentUnavailableView(
                    "No MCP Servers",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Add servers in ~/.claude/settings.json")
                )
            } else {
                List(config.servers, selection: $selectedServer) { server in
                    serverRow(server)
                        .tag(server)
                }
                .listStyle(.sidebar)
            }

            if let error = config.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
        }
        .onChange(of: selectedServer) { _, server in
            loadServerDetail(server)
        }
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        HStack(spacing: 8) {
            Image(systemName: serverIcon(server))
                .font(.system(size: 14))
                .foregroundStyle(serverColor(server))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.callout.weight(.medium))
                Text(server.shortPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if config.isAutoAllowed(server.name) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help("Auto-allowed")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        if let server = selectedServer {
            VStack(spacing: 0) {
                // Header
                serverHeader(server)

                Divider()

                // Tabs: Info / Source / Tools
                if isEditing {
                    sourceEditor(server)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            infoSection(server)
                            toolsSection
                        }
                        .padding(16)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Select a Server",
                systemImage: "puzzlepiece.extension",
                description: Text("Choose an MCP server from the list to view details")
            )
        }
    }

    private func serverHeader(_ server: MCPServerConfig) -> some View {
        HStack(spacing: 12) {
            Image(systemName: serverIcon(server))
                .font(.title2)
                .foregroundStyle(serverColor(server))

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.title3.weight(.semibold))

                HStack(spacing: 6) {
                    Label(server.command, systemImage: "terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if config.isAutoAllowed(server.name) {
                        Text("Auto-allowed")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .cornerRadius(4)
                    }

                    if server.isLocal {
                        Text("Local")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .cornerRadius(4)
                    }
                }
            }

            Spacer()

            if server.sourcePath != nil {
                Button {
                    isEditing.toggle()
                } label: {
                    Label(isEditing ? "View Info" : "Edit Source", systemImage: isEditing ? "info.circle" : "pencil")
                }
                .buttonStyle(.bordered)

                Button {
                    config.openInEditor(server: server)
                } label: {
                    Label("Open in Editor", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
    }

    private func infoSection(_ server: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Configuration")

            infoRow("Command", value: server.command)
            infoRow("Arguments", value: server.args.joined(separator: " "))

            if let path = server.sourcePath {
                infoRow("Source", value: path)
            }

            if !server.env.isEmpty {
                sectionHeader("Environment")
                ForEach(Array(server.env.keys.sorted()), id: \.self) { key in
                    let value = server.env[key] ?? ""
                    // Mask potential secrets
                    let display = (key.lowercased().contains("key") || key.lowercased().contains("token") || key.lowercased().contains("secret"))
                        ? String(value.prefix(4)) + "..."
                        : value
                    infoRow(key, value: display)
                }
            }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Tools (\(parsedTools.count))")

            if parsedTools.isEmpty {
                Text("No tools found — source may use a different pattern")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(parsedTools) { tool in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "wrench")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                                .font(.callout.monospaced().weight(.medium))
                            if !tool.description.isEmpty {
                                Text(tool.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Source Editor

    private func sourceEditor(_ server: MCPServerConfig) -> some View {
        VStack(spacing: 0) {
            // Editor toolbar
            HStack {
                Text(server.shortPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()

                if let error = saveError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Save") {
                    saveSource(server)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))

            Divider()

            // Text editor
            TextEditor(text: $sourceText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
        }
        .alert("Saved", isPresented: $showSaveConfirm) {
            Button("OK") {}
        } message: {
            Text("Source file updated. Restart the MCP server to apply changes.")
        }
    }

    // MARK: - Helpers

    private func loadServerDetail(_ server: MCPServerConfig?) {
        guard let server else {
            sourceText = ""
            parsedTools = []
            isEditing = false
            return
        }
        isEditing = false
        saveError = nil
        if let source = config.sourceContents(for: server) {
            sourceText = source
            parsedTools = config.parseTools(from: source)
        } else {
            sourceText = ""
            parsedTools = []
        }
    }

    private func saveSource(_ server: MCPServerConfig) {
        do {
            try config.saveSource(for: server, contents: sourceText)
            parsedTools = config.parseTools(from: sourceText)
            saveError = nil
            showSaveConfirm = true
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private func serverIcon(_ server: MCPServerConfig) -> String {
        switch server.name {
        case "cortana": return "brain.head.profile"
        case "scout": return "binoculars"
        case "qmd": return "doc.text.magnifyingglass"
        case "pencil": return "pencil.and.outline"
        case "codex": return "books.vertical"
        case "forge-workflow": return "hammer"
        default:
            if server.isNPX { return "shippingbox" }
            if server.isLocal { return "desktopcomputer" }
            return "puzzlepiece.extension"
        }
    }

    private func serverColor(_ server: MCPServerConfig) -> Color {
        switch server.name {
        case "cortana": return .purple
        case "scout": return .orange
        case "qmd": return .cyan
        case "pencil": return .pink
        case "codex": return .indigo
        case "forge-workflow": return .yellow
        default: return .secondary
        }
    }
}
