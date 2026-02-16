import SwiftUI

/// TMUX-style integrated terminal view
struct TerminalView: View {
    @StateObject private var viewModel: TerminalViewModel
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    init(sessionId: String, gatewayClient: GatewayClient) {
        _viewModel = StateObject(wrappedValue: TerminalViewModel(
            sessionId: sessionId,
            gatewayClient: gatewayClient
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Terminal output area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.lines) { line in
                            TerminalLine(line: line)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .black))
                .onChange(of: viewModel.lines.count) { _ in
                    if let lastLine = viewModel.lines.last {
                        proxy.scrollTo(lastLine.id, anchor: .bottom)
                    }
                }
            }

            // Input prompt area
            HStack(spacing: 4) {
                Text(viewModel.prompt)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.green)

                TextField("", text: $inputText)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .foregroundColor(Color(nsColor: .white))
                    .focused($isInputFocused)
                    .onSubmit {
                        viewModel.sendCommand(inputText)
                        inputText = ""
                    }
            }
            .padding(8)
            .background(Color(nsColor: .black))
        }
        .onAppear {
            isInputFocused = true
            viewModel.startStreaming()
        }
        .onDisappear {
            viewModel.stopStreaming()
        }
    }
}

struct TerminalLine: View {
    let line: TerminalOutputLine

    var body: some View {
        Text(line.text)
            .font(.system(.body, design: .monospaced))
            .foregroundColor(parseColor(from: line.text))
            .textSelection(.enabled)
    }

    private func parseColor(from text: String) -> Color {
        // Basic ANSI color parsing (can be enhanced)
        if text.contains("\u{001B}[31m") { return .red }
        if text.contains("\u{001B}[32m") { return .green }
        if text.contains("\u{001B}[33m") { return .yellow }
        if text.contains("\u{001B}[34m") { return .blue }
        if text.contains("\u{001B}[35m") { return .purple }
        if text.contains("\u{001B}[36m") { return .cyan }
        if text.contains("\u{001B}[90m") { return .gray }
        return .white
    }
}

@MainActor
class TerminalViewModel: ObservableObject {
    @Published var lines: [TerminalOutputLine] = []
    @Published var prompt = "$ "
    @Published var isStreaming = false

    private let sessionId: String
    private let gatewayClient: GatewayClient
    private var streamTask: Task<Void, Never>?

    init(sessionId: String, gatewayClient: GatewayClient) {
        self.sessionId = sessionId
        self.gatewayClient = gatewayClient
    }

    func startStreaming() {
        guard !isStreaming else { return }
        isStreaming = true

        streamTask = Task {
            for await output in gatewayClient.subscribeToTerminal(sessionId: sessionId) {
                parseAndAppendOutput(output)
            }
        }
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    func sendCommand(_ command: String) {
        guard !command.isEmpty else { return }

        // Echo command to display
        lines.append(TerminalOutputLine(
            text: prompt + command,
            color: .white
        ))

        // Send to gateway
        Task {
            do {
                try await gatewayClient.sendTerminalCommand(
                    sessionId: sessionId,
                    command: command
                )
            } catch {
                lines.append(TerminalOutputLine(
                    text: "Error: \(error.localizedDescription)",
                    color: .red
                ))
            }
        }
    }

    private func parseAndAppendOutput(_ output: String) {
        // Split by newlines and create individual lines
        let outputLines = output.split(separator: "\n", omittingEmptySubsequences: false)
        for line in outputLines {
            lines.append(TerminalOutputLine(
                text: String(line),
                color: .white
            ))
        }

        // Limit buffer to prevent memory issues
        if lines.count > 10000 {
            lines.removeFirst(lines.count - 10000)
        }
    }
}

struct TerminalOutputLine: Identifiable {
    let id = UUID()
    let text: String
    let color: Color
}

// MARK: - Terminal List View

struct TerminalListView: View {
    @StateObject private var viewModel: TerminalListViewModel
    @State private var showingNewTerminal = false

    init(gatewayClient: GatewayClient) {
        _viewModel = StateObject(wrappedValue: TerminalListViewModel(gatewayClient: gatewayClient))
    }

    var body: some View {
        NavigationStack {
            List(viewModel.terminals) { terminal in
                NavigationLink {
                    TerminalView(
                        sessionId: terminal.id,
                        gatewayClient: viewModel.gatewayClient
                    )
                } label: {
                    TerminalRowView(terminal: terminal)
                }
            }
            .navigationTitle("Terminals")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingNewTerminal = true }) {
                        Label("New Terminal", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewTerminal) {
                NewTerminalSheet(
                    gatewayClient: viewModel.gatewayClient,
                    onCreated: { terminal in
                        viewModel.terminals.append(terminal)
                        showingNewTerminal = false
                    }
                )
            }
        }
        .onAppear {
            viewModel.loadTerminals()
        }
    }
}

struct TerminalRowView: View {
    let terminal: TerminalInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(terminal.name ?? "Terminal \(terminal.id.prefix(8))")
                .font(.headline)

            HStack {
                Text(terminal.project ?? "general")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(terminal.status)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch terminal.status {
        case "running": return .green
        case "stopped": return .gray
        default: return .orange
        }
    }
}

@MainActor
class TerminalListViewModel: ObservableObject {
    @Published var terminals: [TerminalInfo] = []

    let gatewayClient: GatewayClient

    init(gatewayClient: GatewayClient) {
        self.gatewayClient = gatewayClient
    }

    func loadTerminals() {
        // TODO: Implement terminal list endpoint in gateway
        // For now, mock data
        terminals = []
    }
}

struct TerminalInfo: Identifiable {
    let id: String
    let name: String?
    let project: String?
    let status: String
}

// MARK: - New Terminal Sheet

struct NewTerminalSheet: View {
    let gatewayClient: GatewayClient
    let onCreated: (TerminalInfo) -> Void

    @State private var command = "bash"
    @State private var workingDirectory = ""
    @State private var project = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Configuration") {
                    TextField("Command", text: $command)
                    TextField("Working Directory", text: $workingDirectory)
                        .textFieldStyle(.roundedBorder)
                    TextField("Project", text: $project)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .navigationTitle("New Terminal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createTerminal()
                    }
                }
            }
        }
    }

    private func createTerminal() {
        // TODO: Implement terminal creation via gateway
        let terminal = TerminalInfo(
            id: UUID().uuidString,
            name: "Terminal",
            project: project.isEmpty ? nil : project,
            status: "running"
        )
        onCreated(terminal)
    }
}
