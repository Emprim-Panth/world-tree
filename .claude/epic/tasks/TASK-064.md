# TASK-064: feat: Voice mode (speech-to-text + TTS response)

**Status:** Pending
**Priority:** High
**Assignee:** Unassigned
**Created:** 2026-03-03
**Updated:** 2026-03-03

---

## Description

Hands-free voice interaction: hold mic button to dictate, Cortana's response reads aloud via AVSpeechSynthesizer.

## Acceptance Criteria

- [ ] Mic button in MessageInputView (long-press or tap-to-toggle)
- [ ] Speech recognition via `SFSpeechRecognizer` (on-device, no API cost)
- [ ] Live transcription shown in text field as user speaks
- [ ] Release/tap-stop sends the message
- [ ] `AVSpeechSynthesizer` reads assistant responses aloud (opt-in setting)
- [ ] TTS pauses when new dictation starts
- [ ] Microphone + speech recognition permissions requested on first use

## Implementation Notes

- `SFSpeechRecognizer` — on-device recognition (iOS 13+, no network needed)
- `AVAudioSession` category: `.playAndRecord` with `.defaultToSpeaker`
- TTS: `AVSpeechUtterance` with system voice; rate/pitch configurable in Settings
- Interrupt handling: stop TTS when user starts speaking
- UI: mic button animates (pulse) while recording; waveform optional
