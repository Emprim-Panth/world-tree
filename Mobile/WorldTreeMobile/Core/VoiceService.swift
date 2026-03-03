import Foundation
import AVFoundation
import Speech

// MARK: - Speech Delegate

/// Bridges AVSpeechSynthesizerDelegate (NSObject-based) back into the VoiceService actor.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
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

/// Voice Service — on-device STT via SFSpeechRecognizer + TTS via AVSpeechSynthesizer.
/// No API keys, no network required. On-device only.
actor VoiceService {
    static let shared = VoiceService()

    // MARK: - Speech Recognition (Input)

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private(set) var isListening = false
    private var lastPartialText: String = ""

    // MARK: - Text-to-Speech (Output)

    private let synthesizer = AVSpeechSynthesizer()
    private var speechDelegate: SpeechDelegate?
    private(set) var isSpeaking = false

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

    private init() {}

    private func ensureDelegateConfigured() {
        guard speechDelegate == nil else { return }
        let delegate = SpeechDelegate(service: self)
        speechDelegate = delegate
        synthesizer.delegate = delegate
    }

    // MARK: - Permissions

    /// Request microphone + speech recognition permissions. Returns true if both granted.
    func requestPermissions() async -> Bool {
        // Microphone
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard granted else {
            postError("Microphone access denied. Enable it in Settings > Privacy & Security > Microphone.")
            return false
        }

        // Speech recognition
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .authorized:
            break
        case .notDetermined:
            let speechGranted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            guard speechGranted else {
                postError("Speech recognition denied. Enable it in Settings > Privacy & Security > Speech Recognition.")
                return false
            }
        default:
            postError("Speech recognition denied. Enable it in Settings > Privacy & Security > Speech Recognition.")
            return false
        }

        return true
    }

    // MARK: - Voice Input

    /// Start live transcription. Transcription results stream via NotificationCenter.
    func startListening() async throws {
        guard !isListening else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw VoiceError.audioEngineError
        }

        // Configure AVAudioSession for recording + playback
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16, *) {
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

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { await self?.handleRecognitionResult(result, error: error) }
        }
    }

    /// Stop listening and finalize transcription.
    func stopListening() {
        guard isListening else { return }

        // Flush any partial text as final before tearing down
        if !lastPartialText.isEmpty {
            postTranscription(lastPartialText, isFinal: true)
            lastPartialText = ""
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        isListening = false
        postListeningState(false)

        // Restore audio session for playback
        Task {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        }
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            lastPartialText = isFinal ? "" : text
            postTranscription(text, isFinal: isFinal)
            if isFinal { stopListening() }
        }

        if let error {
            let nsError = error as NSError
            // kAFAssistantErrorDomain 216 = timeout — not a real error
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                if !lastPartialText.isEmpty {
                    postTranscription(lastPartialText, isFinal: true)
                    lastPartialText = ""
                }
                stopListening()
                return
            }
            postError(error.localizedDescription)
            stopListening()
        }
    }

    // MARK: - Voice Output (TTS)

    func speak(_ text: String) {
        guard !isSpeaking else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ensureDelegateConfigured()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.pitchMultiplier = 1.0
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    func markSpeakingDone() {
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

// MARK: - Error

enum VoiceError: Error, LocalizedError {
    case audioEngineError
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .audioEngineError: return "Speech recognition is not available on this device"
        case .permissionDenied: return "Microphone or speech recognition permission denied"
        }
    }
}
