import Foundation
import AVFoundation

/// Voice Service Extension - System-wide voice interaction framework
/// This is not a feature - it's a capability that permeates the entire system
actor VoiceService {
    static let shared = VoiceService()

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = AVSpeechSynthesizer()
    private var isListening = false
    private var continuousMode = false

    // Voice providers (extensible)
    private var providers: [VoiceProvider] = []
    private var activeProvider: VoiceProvider?

    // Voice commands (extensible)
    private var commandRegistry: [VoiceCommand] = []

    // Voice state
    private var currentTranscription = ""
    private var conversationContext: [VoiceMessage] = []

    private init() {
        setupProviders()
        registerSystemCommands()
    }

    // MARK: - Provider Management

    private func setupProviders() {
        // Whisper API for transcription
        providers.append(WhisperProvider())

        // Elevenlabs for high-quality TTS
        if let elevenLabsKey = loadElevenlabsKey() {
            providers.append(ElevenlabsProvider(apiKey: elevenLabsKey))
        }

        // System fallback
        providers.append(SystemTTSProvider())

        // Set default active provider
        activeProvider = providers.first
    }

    func registerProvider(_ provider: VoiceProvider) {
        providers.append(provider)
    }

    func setActiveProvider(_ providerType: VoiceProviderType) {
        activeProvider = providers.first { $0.type == providerType }
    }

    // MARK: - Voice Input (Continuous & Command)

    func startListening(mode: ListeningMode = .continuous) async throws {
        guard !isListening else { return }

        isListening = true
        continuousMode = (mode == .continuous)

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Install tap for audio capture
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            Task {
                await self?.processAudioBuffer(buffer)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stopListening() {
        isListening = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async {
        // Detect speech/silence
        let level = calculateAudioLevel(buffer)

        if level > silenceThreshold {
            // Speech detected - accumulate buffer
            await accumulateAudio(buffer)
        } else if !accumulatedBuffers.isEmpty {
            // Silence after speech - transcribe
            await transcribeAccumulatedAudio()
        }
    }

    private var accumulatedBuffers: [AVAudioPCMBuffer] = []
    private let silenceThreshold: Float = 0.02

    private func accumulateAudio(_ buffer: AVAudioPCMBuffer) {
        accumulatedBuffers.append(buffer)

        // Limit buffer size (30 seconds max)
        if accumulatedBuffers.count > 1320 { // 44100 Hz / 4096 * 30 sec
            accumulatedBuffers.removeFirst()
        }
    }

    private func transcribeAccumulatedAudio() async {
        guard !accumulatedBuffers.isEmpty else { return }
        guard let provider = activeProvider else { return }

        // Combine buffers into single audio file
        let audioData = combineBuffers(accumulatedBuffers)
        accumulatedBuffers.removeAll()

        do {
            let transcription = try await provider.transcribe(audioData: audioData)
            currentTranscription = transcription

            // Check for voice commands first
            if let command = matchCommand(transcription) {
                await executeCommand(command, with: transcription)
            } else if continuousMode {
                // Continuous conversation mode
                await processConversation(transcription)
            } else {
                // Single-shot dictation
                await notifyTranscription(transcription)
            }
        } catch {
            print("Transcription error: \(error)")
        }
    }

    // MARK: - Voice Output (TTS)

    func speak(_ text: String, options: SpeechOptions = .default) async throws {
        guard let provider = activeProvider else {
            throw VoiceError.noProvider
        }

        let audioData = try await provider.synthesize(text: text, options: options)
        await playAudio(audioData)
    }

    private func playAudio(_ data: Data) async {
        // TODO: Implement audio playback
        // For now, use system TTS as fallback
        let utterance = AVSpeechUtterance(string: String(data: data, encoding: .utf8) ?? "")
        speechRecognizer.speak(utterance)
    }

    // MARK: - Voice Commands (Extensible)

    private func registerSystemCommands() {
        // Navigation commands
        registerCommand(VoiceCommand(
            triggers: ["create branch", "new branch", "branch from here"],
            action: .createBranch
        ))

        registerCommand(VoiceCommand(
            triggers: ["search for", "find", "show me"],
            action: .search
        ))

        registerCommand(VoiceCommand(
            triggers: ["stop listening", "pause", "be quiet"],
            action: .stopListening
        ))

        // Context commands
        registerCommand(VoiceCommand(
            triggers: ["show context", "context window", "how much context"],
            action: .showContext
        ))

        // Terminal commands
        registerCommand(VoiceCommand(
            triggers: ["open terminal", "new terminal", "show terminal"],
            action: .openTerminal
        ))
    }

    func registerCommand(_ command: VoiceCommand) {
        commandRegistry.append(command)
    }

    private func matchCommand(_ text: String) -> VoiceCommand? {
        let lowercased = text.lowercased()
        return commandRegistry.first { command in
            command.triggers.contains { trigger in
                lowercased.contains(trigger.lowercased())
            }
        }
    }

    private func executeCommand(_ command: VoiceCommand, with text: String) async {
        // Notify listeners about command execution
        await notifyCommand(command, text: text)
    }

    // MARK: - Continuous Conversation

    private func processConversation(_ text: String) async {
        conversationContext.append(VoiceMessage(role: .user, content: text))

        // TODO: Send to Claude for response via gateway
        // For now, acknowledge
        let response = "I heard: \(text)"
        conversationContext.append(VoiceMessage(role: .assistant, content: response))

        try? await speak(response)
    }

    // MARK: - Notifications (Observer Pattern)

    private var transcriptionListeners: [(String) -> Void] = []
    private var commandListeners: [(VoiceCommand, String) -> Void] = []

    func onTranscription(_ listener: @escaping (String) -> Void) {
        transcriptionListeners.append(listener)
    }

    func onCommand(_ listener: @escaping (VoiceCommand, String) -> Void) {
        commandListeners.append(listener)
    }

    private func notifyTranscription(_ text: String) async {
        for listener in transcriptionListeners {
            listener(text)
        }
    }

    private func notifyCommand(_ command: VoiceCommand, text: String) async {
        for listener in commandListeners {
            listener(command, text)
        }
    }

    // MARK: - Utilities

    private func calculateAudioLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let channelDataArray = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))

        let rms = sqrt(channelDataArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))
        return rms
    }

    private func combineBuffers(_ buffers: [AVAudioPCMBuffer]) -> Data {
        // TODO: Implement buffer combination
        return Data()
    }

    private func loadElevenlabsKey() -> String? {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cortana/voice/config.toml")

        guard let content = try? String(contentsOf: configPath) else { return nil }

        // Parse TOML for elevenlabs_key
        let pattern = #"elevenlabs_key\s*=\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let keyRange = Range(match.range(at: 1), in: content) {
            return String(content[keyRange])
        }

        return nil
    }
}

// MARK: - Models

enum ListeningMode {
    case continuous  // Ongoing conversation
    case pushToTalk  // Single utterance
    case command     // Command detection only
}

struct VoiceMessage {
    let role: Role
    let content: String
    let timestamp: Date = Date()

    enum Role {
        case user
        case assistant
        case system
    }
}

struct VoiceCommand: Identifiable {
    let id = UUID()
    let triggers: [String]
    let action: CommandAction

    enum CommandAction {
        case createBranch
        case search
        case stopListening
        case showContext
        case openTerminal
        case custom(String)
    }
}

struct SpeechOptions {
    var voice: String?
    var speed: Double
    var pitch: Double

    static let `default` = SpeechOptions(speed: 1.0, pitch: 1.0)
}

enum VoiceError: Error {
    case noProvider
    case transcriptionFailed
    case synthesisFailed
    case audioEngineError
}

// MARK: - Provider Protocol (Extensible)

protocol VoiceProvider {
    var type: VoiceProviderType { get }

    func transcribe(audioData: Data) async throws -> String
    func synthesize(text: String, options: SpeechOptions) async throws -> Data
}

enum VoiceProviderType {
    case whisper
    case elevenlabs
    case system
    case custom(String)
}

// MARK: - Provider Implementations

struct WhisperProvider: VoiceProvider {
    let type: VoiceProviderType = .whisper

    func transcribe(audioData: Data) async throws -> String {
        // TODO: Implement Whisper API call
        return "Transcribed text"
    }

    func synthesize(text: String, options: SpeechOptions) async throws -> Data {
        throw VoiceError.synthesisFailed
    }
}

struct ElevenlabsProvider: VoiceProvider {
    let type: VoiceProviderType = .elevenlabs
    let apiKey: String

    func transcribe(audioData: Data) async throws -> String {
        throw VoiceError.transcriptionFailed
    }

    func synthesize(text: String, options: SpeechOptions) async throws -> Data {
        // TODO: Implement Elevenlabs API call
        return Data()
    }
}

struct SystemTTSProvider: VoiceProvider {
    let type: VoiceProviderType = .system

    func transcribe(audioData: Data) async throws -> String {
        throw VoiceError.transcriptionFailed
    }

    func synthesize(text: String, options: SpeechOptions) async throws -> Data {
        // Use AVSpeechSynthesizer
        return text.data(using: .utf8) ?? Data()
    }
}
