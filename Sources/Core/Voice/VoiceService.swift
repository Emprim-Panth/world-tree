import Foundation
import AVFoundation
import Speech

// MARK: - Speech Delegate

/// Bridges AVSpeechSynthesizerDelegate (NSObject-based) back into the VoiceService actor.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    // Weak to avoid a retain cycle: actor → delegate → actor.
    private weak var service: VoiceService?

    init(service: VoiceService) {
        self.service = service
        super.init()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let service else { return }
        Task { await service.markSpeakingDone() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard let service else { return }
        Task { await service.markSpeakingDone() }
    }
}

// MARK: - VoiceService

/// Voice Service — handles both voice input (STT) and voice output (TTS).
///
/// Input uses Apple's on-device SFSpeechRecognizer — no API keys, no network.
/// Output uses AVSpeechSynthesizer with speed/pitch controls (cortana soul additions).
/// External providers (ElevenLabs) can be added for higher-quality TTS.
actor VoiceService {
    static let shared = VoiceService()

    // MARK: - Speech Recognition (Input)

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private(set) var isListening = false

    // MARK: - Text-to-Speech (Output)

    private let synthesizer = AVSpeechSynthesizer()
    private var speechDelegate: SpeechDelegate?
    private var isSpeaking = false
    private var audioPlayer: AVAudioPlayer?

    // MARK: - Notifications

    /// Posted on MainActor when live transcription updates arrive.
    /// userInfo: ["text": String, "isFinal": Bool]
    static let transcriptionUpdated = Notification.Name("VoiceService.transcriptionUpdated")

    /// Posted on MainActor when listening state changes.
    /// userInfo: ["isListening": Bool]
    static let listeningStateChanged = Notification.Name("VoiceService.listeningStateChanged")

    /// Posted on MainActor when an error occurs.
    /// userInfo: ["error": String]
    static let voiceError = Notification.Name("VoiceService.voiceError")

    private init() {
        let delegate = SpeechDelegate(service: self)
        speechDelegate = delegate
        synthesizer.delegate = delegate
    }

    // MARK: - Permissions

    /// Request microphone + speech recognition permissions. Returns true if both granted.
    /// Only shows system dialogs when status is .notDetermined — already granted/denied are fast-paths.
    func requestPermissions() async -> Bool {
        // Microphone
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            break // already granted
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            guard granted else {
                postError("Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone.")
                return false
            }
        default:
            postError("Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone.")
            return false
        }

        // Speech recognition
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .authorized:
            break // already granted
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            guard granted else {
                postError("Speech recognition denied. Enable it in System Settings > Privacy & Security > Speech Recognition.")
                return false
            }
        default:
            postError("Speech recognition denied. Enable it in System Settings > Privacy & Security > Speech Recognition.")
            return false
        }

        return true
    }

    // MARK: - Voice Input (SFSpeechRecognizer)

    /// Start live transcription. Results stream via NotificationCenter.
    func startListening() async throws {
        guard !isListening else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw VoiceError.audioEngineError
        }

        // Cancel any prior task
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device only — no network, faster, private
        if #available(macOS 13, *) {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isListening = true
        postListeningState(true)

        // Start recognition — results arrive via delegate callback
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { await self?.handleRecognitionResult(result, error: error) }
        }
    }

    /// Stop listening and finalize transcription.
    func stopListening() {
        guard isListening else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        isListening = false
        postListeningState(false)
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            postTranscription(text, isFinal: isFinal)

            if isFinal {
                stopListening()
            }
        }

        if let error {
            // Don't report cancellation as an error — that's normal stop behavior
            let nsError = error as NSError
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                // "Retry" — speech recognizer timed out, just stop cleanly
                stopListening()
                return
            }
            postError(error.localizedDescription)
            stopListening()
        }
    }

    // MARK: - Voice Output (TTS) — cortana soul additions preserved

    func speak(_ text: String, options: SpeechOptions = .default) async throws {
        guard !isSpeaking else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        speakWithSystem(text, options: options)
    }

    private func speakWithSystem(_ text: String, options: SpeechOptions) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(options.speed) * AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = Float(options.pitch)
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        isSpeaking = true
        synthesizer.speak(utterance)
        // isSpeaking is reset by SpeechDelegate.speechSynthesizer(_:didFinish:) or didCancel.
    }

    /// Called by SpeechDelegate when the synthesizer finishes or cancels an utterance.
    func markSpeakingDone() {
        isSpeaking = false
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - Notification Helpers

    private func postTranscription(_ text: String, isFinal: Bool) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: VoiceService.transcriptionUpdated,
                object: nil,
                userInfo: ["text": text, "isFinal": isFinal]
            )
        }
    }

    private func postListeningState(_ listening: Bool) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: VoiceService.listeningStateChanged,
                object: nil,
                userInfo: ["isListening": listening]
            )
        }
    }

    private func postError(_ message: String) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: VoiceService.voiceError,
                object: nil,
                userInfo: ["error": message]
            )
        }
    }
}

// MARK: - Models

struct SpeechOptions {
    var voice: String?
    var speed: Double
    var pitch: Double

    static let `default` = SpeechOptions(speed: 1.0, pitch: 1.0)
}

enum VoiceError: Error, LocalizedError {
    case noProvider
    case transcriptionFailed
    case synthesisFailed
    case audioEngineError
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noProvider: return "No voice provider available"
        case .transcriptionFailed: return "Transcription failed"
        case .synthesisFailed: return "Speech synthesis failed"
        case .audioEngineError: return "Audio engine error — speech recognition may not be available"
        case .permissionDenied: return "Microphone or speech recognition permission denied"
        }
    }
}
