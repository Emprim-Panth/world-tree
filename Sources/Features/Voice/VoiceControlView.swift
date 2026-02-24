import SwiftUI
import AVFoundation

/// Floating voice control panel — shows listening state and live transcription.
/// TTS settings live in Settings > Voice (cortana soul additions). This handles input only.
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
        Button(action: {
            if viewModel.isListening {
                viewModel.toggleListening()
            } else {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: viewModel.isListening ? "waveform" : "mic.fill")
                    .font(.system(size: 16))
                    .foregroundColor(viewModel.isListening ? .red : .accentColor)
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
                Text("Voice Input")
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
            Text(viewModel.statusText)
                .font(.caption)
                .foregroundColor(viewModel.errorMessage != nil ? .red : .secondary)

            // Live transcription
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

            // Mic button
            Button(action: { viewModel.toggleListening() }) {
                VStack(spacing: 4) {
                    Image(systemName: viewModel.isListening ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 32))
                        .foregroundColor(viewModel.isListening ? .red : .accentColor)

                    Text(viewModel.isListening ? "Stop" : "Start")
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 80, height: 80)
            .background(viewModel.isListening ? Color.red.opacity(0.1) : Color.accentColor.opacity(0.1))
            .cornerRadius(12)
        }
        .padding(16)
        .frame(width: 280)
    }
}

@MainActor
class VoiceControlViewModel: ObservableObject {
    @Published var isListening = false
    @Published var audioLevel: Double = 0.0
    @Published var currentTranscription = ""
    @Published var errorMessage: String?

    private var levelTimer: Timer?

    var statusText: String {
        if let error = errorMessage { return error }
        if isListening { return "Listening — speak now..." }
        return "Tap to start voice input"
    }

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTranscription),
            name: VoiceService.transcriptionUpdated, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleListeningState),
            name: VoiceService.listeningStateChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleVoiceError),
            name: VoiceService.voiceError, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        levelTimer?.invalidate()
    }

    @objc private func handleTranscription(_ notification: Notification) {
        currentTranscription = notification.userInfo?["text"] as? String ?? ""
    }

    @objc private func handleListeningState(_ notification: Notification) {
        isListening = notification.userInfo?["isListening"] as? Bool ?? false
        if !isListening {
            stopAudioLevelMonitoring()
        }
    }

    @objc private func handleVoiceError(_ notification: Notification) {
        errorMessage = notification.userInfo?["error"] as? String
        // Clear error after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.errorMessage = nil
        }
    }

    func toggleListening() {
        if isListening {
            Task { await VoiceService.shared.stopListening() }
        } else {
            errorMessage = nil
            Task {
                let granted = await VoiceService.shared.requestPermissions()
                guard granted else { return }
                do {
                    try await VoiceService.shared.startListening()
                    startAudioLevelMonitoring()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func startAudioLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                // Simulate audio level — real levels come from the audio engine
                self.audioLevel = Double.random(in: 0.1...0.8)
            }
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
                        Gradient(colors: [.cyan, .blue]),
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
