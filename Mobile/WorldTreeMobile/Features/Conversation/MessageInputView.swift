import SwiftUI
import AVFoundation
import Speech

/// Bottom-pinned message input bar with voice dictation support.
///
/// - Multi-line TextField grows from 1 to 5 lines, then scrolls.
/// - Send button is disabled when text is empty (after trimming) or `isBusy` is true.
/// - Mic button replaces send when text is empty — tap to start/stop dictation.
/// - Return key inserts a newline; the send button is the only text submit action.
/// - Character count appears when the field is non-empty.
struct MessageInputView: View {
    @Binding var text: String
    /// Placeholder text — defaults to "Message…" but callers can supply the branch name.
    var placeholder: String = "Message…"
    let isBusy: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isListening = false
    @State private var voicePermissionError: String?
    @State private var pulseAnimation = false

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                // Mic button (left side, only visible when not busy)
                if !isBusy {
                    micButton
                }

                VStack(alignment: .trailing, spacing: 2) {
                    TextField(isListening ? "Listening…" : placeholder, text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($isFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                    if !text.isEmpty {
                        Text("\(text.count)")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(text.count > 8_000 ? Color.red : Color.secondary)
                            .padding(.trailing, 8)
                            .padding(.bottom, 4)
                    }
                }
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))

                if isBusy {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.red)
                    }
                } else {
                    Button(action: sendAndDismiss) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                            .animation(.easeInOut(duration: 0.15), value: canSend)
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(uiColor: .systemBackground))
        }
        .frame(maxWidth: DesignTokens.Layout.inputBarMaxWidth)
        .onReceive(NotificationCenter.default.publisher(for: VoiceService.transcriptionUpdated)) { note in
            guard let noteText = note.userInfo?["text"] as? String else { return }
            let isFinal = note.userInfo?["isFinal"] as? Bool ?? false
            text = noteText
            if isFinal {
                isListening = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: VoiceService.listeningStateChanged)) { note in
            let listening = note.userInfo?["isListening"] as? Bool ?? false
            isListening = listening
            pulseAnimation = listening
        }
        .onReceive(NotificationCenter.default.publisher(for: VoiceService.voiceError)) { note in
            let msg = note.userInfo?["error"] as? String ?? "Voice error"
            voicePermissionError = msg
            isListening = false
        }
        .alert("Voice Error", isPresented: Binding(
            get: { voicePermissionError != nil },
            set: { if !$0 { voicePermissionError = nil } }
        )) {
            Button("OK") { voicePermissionError = nil }
        } message: {
            if let msg = voicePermissionError {
                Text(msg)
            }
        }
    }

    @ViewBuilder
    private var micButton: some View {
        Button(action: toggleListening) {
            ZStack {
                if isListening {
                    Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 36, height: 36)
                        .scaleEffect(pulseAnimation ? 1.3 : 1.0)
                        .animation(
                            .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                            value: pulseAnimation
                        )
                }
                Image(systemName: isListening ? "waveform" : "mic")
                    .font(.system(size: 18))
                    .foregroundStyle(isListening ? Color.red : Color.secondary)
                    .frame(width: 36, height: 36)
            }
        }
        .buttonStyle(.plain)
    }

    private func toggleListening() {
        if isListening {
            Task { await VoiceService.shared.stopListening() }
        } else {
            // Stop TTS if speaking
            Task { await VoiceService.shared.stopSpeaking() }
            isFocused = false
            text = ""
            Task {
                let permitted = await VoiceService.shared.requestPermissions()
                guard permitted else { return }
                do {
                    try await VoiceService.shared.startListening()
                } catch {
                    voicePermissionError = error.localizedDescription
                }
            }
        }
    }

    private func sendAndDismiss() {
        // Stop listening if active — final transcription will have already updated text
        if isListening {
            Task { await VoiceService.shared.stopListening() }
        }
        isFocused = false
        onSend()
    }
}
