import SwiftUI
import AVFoundation

/// Floating voice control panel - always accessible
struct VoiceControlView: View {
    @StateObject private var viewModel = VoiceControlViewModel()
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                expandedView
            } else {
                compactView
            }
        }
        .background(.ultraThinMaterial)
        .cornerRadius(isExpanded ? 12 : 24)
        .shadow(radius: 8)
        .animation(.spring(response: 0.3), value: isExpanded)
    }

    private var compactView: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: viewModel.isListening ? "waveform" : "mic.fill")
                    .font(.system(size: 16))
                    .foregroundColor(viewModel.isListening ? .red : .blue)
                    .symbolEffect(.variableColor.iterative, isActive: viewModel.isListening)

                if viewModel.isListening {
                    Text("Listening...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private var expandedView: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Voice Control")
                    .font(.headline)

                Spacer()

                Button(action: { isExpanded = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Waveform visualizer
            WaveformView(amplitude: viewModel.audioLevel)
                .frame(height: 60)

            // Status
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)

            // Transcription
            if !viewModel.currentTranscription.isEmpty {
                ScrollView {
                    Text(viewModel.currentTranscription)
                        .font(.body)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                }
                .frame(maxHeight: 100)
            }

            // Controls
            HStack(spacing: 12) {
                // Push-to-talk / Continuous toggle
                Button(action: { viewModel.toggleListening() }) {
                    VStack(spacing: 4) {
                        Image(systemName: viewModel.isListening ? "mic.fill" : "mic.slash.fill")
                            .font(.system(size: 32))
                            .foregroundColor(viewModel.isListening ? .red : .blue)

                        Text(viewModel.isListening ? "Stop" : "Start")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 80, height: 80)
                .background(viewModel.isListening ? Color.red.opacity(0.1) : Color.blue.opacity(0.1))
                .cornerRadius(12)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Continuous Mode", isOn: $viewModel.continuousMode)
                        .toggleStyle(.switch)
                        .font(.caption)

                    Toggle("Commands Only", isOn: $viewModel.commandsOnly)
                        .toggleStyle(.switch)
                        .font(.caption)

                    Picker("Provider", selection: $viewModel.selectedProvider) {
                        Text("Whisper").tag(0)
                        Text("Elevenlabs").tag(1)
                        Text("System").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .font(.caption2)
                }
            }

            // Recent commands
            if !viewModel.recentCommands.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Commands")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)

                    ForEach(viewModel.recentCommands.prefix(3), id: \.self) { command in
                        HStack {
                            Image(systemName: "command")
                                .font(.system(size: 10))
                                .foregroundColor(.blue)

                            Text(command)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var statusText: String {
        if viewModel.isListening {
            return viewModel.continuousMode ? "Continuous conversation..." : "Listening for input..."
        } else if viewModel.isProcessing {
            return "Processing..."
        } else {
            return "Ready to listen"
        }
    }
}

@MainActor
class VoiceControlViewModel: ObservableObject {
    @Published var isListening = false
    @Published var isProcessing = false
    @Published var audioLevel: Double = 0.0
    @Published var currentTranscription = ""
    @Published var continuousMode = false
    @Published var commandsOnly = false
    @Published var selectedProvider = 0
    @Published var recentCommands: [String] = []

    private var levelTimer: Timer?

    init() {
        setupVoiceService()
    }

    private func setupVoiceService() {
        Task {
            // Listen for transcriptions
            await VoiceService.shared.onTranscription { [weak self] text in
                Task { @MainActor in
                    self?.currentTranscription = text
                }
            }

            // Listen for commands
            await VoiceService.shared.onCommand { [weak self] command, text in
                Task { @MainActor in
                    self?.recentCommands.insert(text, at: 0)
                    if self?.recentCommands.count ?? 0 > 10 {
                        self?.recentCommands.removeLast()
                    }
                }
            }
        }
    }

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        isListening = true

        Task {
            do {
                let mode: ListeningMode = commandsOnly ? .command : (continuousMode ? .continuous : .pushToTalk)
                try await VoiceService.shared.startListening(mode: mode)

                // Start audio level monitoring
                startAudioLevelMonitoring()
            } catch {
                print("Failed to start listening: \(error)")
                isListening = false
            }
        }
    }

    private func stopListening() {
        isListening = false

        Task {
            await VoiceService.shared.stopListening()
            stopAudioLevelMonitoring()
        }
    }

    private func startAudioLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            // Simulate audio level (replace with actual audio level from service)
            self?.audioLevel = Double.random(in: 0...1) * (self?.isListening == true ? 1.0 : 0.1)
        }
    }

    private func stopAudioLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0.0
    }
}

// MARK: - Waveform Visualizer

struct WaveformView: View {
    let amplitude: Double
    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let path = createWaveformPath(size: size, time: timeline.date.timeIntervalSinceReferenceDate)

                context.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [.blue, .purple]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)
                    ),
                    lineWidth: 3
                )
            }
        }
    }

    private func createWaveformPath(size: CGSize, time: TimeInterval) -> Path {
        var path = Path()

        let midY = size.height / 2
        let wavelength = size.width / 4
        let frequency = 2.0

        path.move(to: CGPoint(x: 0, y: midY))

        for x in stride(from: 0, through: size.width, by: 2) {
            let relativeX = x / wavelength
            let sine = sin((relativeX + time * frequency) * .pi * 2)
            let y = midY + sine * amplitude * (size.height / 2) * 0.8

            path.addLine(to: CGPoint(x: x, y: y))
        }

        return path
    }
}

// MARK: - Voice Integration Extension

extension View {
    /// Add voice control to any view
    func voiceEnabled() -> some View {
        self.overlay(alignment: .bottomTrailing) {
            VoiceControlView()
                .padding(16)
        }
    }
}
