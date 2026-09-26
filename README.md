# Meeting Assistant (macOS)

A native macOS menu-bar app that listens to your Mac's **system audio** (the other
people on a Zoom / Meet / Teams call) **and** your microphone, transcribes both
**on-device** in real time, and on a hotkey sends the recent transcript to Claude
for concise, live help in a floating overlay only on your screen.

Compiles on macOS 26 CI (universal arm64 + x86_64) and publishes a downloadable
`.app` on each release.

## What it does

```
system audio (ScreenCaptureKit)  -> "Them" transcriber -\
microphone (AVAudioEngine)       -> "You"  transcriber -/
      -> merged, speaker-labeled transcript
      -> [⌘⇧Space] -> Claude Messages API (streaming)
      -> floating overlay (local, non-activating)
```

## Features

- Two-sided, on-device transcription: system audio (them) + microphone (you),
  merged and speaker-labeled.
- On-device STT: SpeechAnalyzer on macOS 26+, SFSpeechRecognizer on 14–15.
- Optional **Deepgram** cloud STT for the hardest audio (opt-in in Settings).
- Live Claude answers in a floating overlay, streamed token by token.
- **Settings (⌘,)**: API key in the macOS Keychain, model picker (Haiku / Sonnet /
  Opus), editable extra instructions, profile.
- **Auto-answer** when the other side asks a question; copy/clear transcript.
- Global hotkeys: ⌘⇧Space to answer, ⌘⇧H to toggle the overlay.

## Requirements

- macOS 14+ at runtime (SpeechAnalyzer path activates on macOS 26+).
- Xcode 26+ to build (macOS 26 SDK defines SpeechAnalyzer; the app still deploys to 14).
- [XcodeGen](https://github.com/yonsm/XcodeGen) (`brew install xcodegen`).
- An Anthropic API key (and optionally a Deepgram key).

## Build it

```bash
git clone https://github.com/stephenlthorn/meeting-assistant.git
cd meeting-assistant
./scripts/bootstrap.sh     # installs XcodeGen if needed, generates the project, opens Xcode
```

Or manually: `brew install xcodegen && xcodegen generate && open MeetingAssistant.xcodeproj`.

Select the **MeetingAssistant** scheme and Run (⌘R). The app has no dock icon; look
for the waveform icon in the menu bar. Open **Settings (⌘,)** and paste your
Anthropic API key (stored in the Keychain). The env var `ANTHROPIC_API_KEY` and
`~/.config/meeting-assistant/anthropic_key` work as fallbacks.

## Download a prebuilt app

Grab `MeetingAssistant.app.zip` from the latest [Release](../../releases/latest),
or from the **Actions** tab (latest `build` run > Artifacts). It is unsigned, so
clear quarantine before first launch:

```bash
unzip MeetingAssistant.app.zip
xattr -dr com.apple.quarantine MeetingAssistant.app
open MeetingAssistant.app
```

To cut a new release, bump `VERSION` (e.g. `v0.1.1`) and push; the release workflow
builds and publishes it.

## Permissions

On first use macOS prompts for **Screen Recording** (ScreenCaptureKit),
**Microphone**, and **Speech Recognition**. Deny the mic and the app runs with
their side only.

## Speech-to-text

On-device is the default (private, free, offline). For the hardest audio, enable
**Deepgram** in Settings and paste a Deepgram key; call audio is then streamed to
Deepgram. Speaker labels come from the mic/system split, not diarization.

## File map

| File | Responsibility |
|------|----------------|
| `Sources/Audio/SystemAudioCapture.swift` | ScreenCaptureKit system-audio capture (them) |
| `Sources/Audio/MicCapture.swift` | AVAudioEngine microphone capture (you) |
| `Sources/Audio/LiveTranscriber.swift` | Transcriber protocol + backend factory |
| `Sources/Audio/AnalyzerTranscriber.swift` | macOS 26+ SpeechAnalyzer backend |
| `Sources/Audio/LegacySpeechTranscriber.swift` | macOS 14–15 SFSpeechRecognizer fallback |
| `Sources/Audio/CloudTranscriber.swift` | Optional Deepgram cloud STT (WebSocket) |
| `Sources/LLM/LLMClient.swift` | Streaming Claude Messages API client |
| `Sources/LLM/Profiles.swift` | Per-use-case system prompts |
| `Sources/App/AssistantController.swift` | Pipeline wiring, transcript merge, state |
| `Sources/UI/OverlayPanel.swift` / `OverlayView.swift` | Floating overlay |
| `Sources/UI/SettingsView.swift` | Preferences window |
| `Sources/System/AppSettings.swift` / `KeychainStore.swift` | Settings + Keychain |
| `Sources/System/HotKeyManager.swift` | Global hotkeys (Carbon) |
| `Sources/App/MeetingAssistantApp.swift` | App entry, menu bar, Settings scene |

## Notes

- **Latency**: ~1.5–3s speech-to-answer, dominated by model choice; Haiku is fastest.
- **Screen sharing**: the overlay is a local window, invisible to the other side
  when you are not screen sharing. `sharingType = .none` does not hide it from
  ScreenCaptureKit-based full-screen shares on macOS 15+.
- **Signing**: dev config only (no sandbox / hardened runtime). CI builds are
  unsigned; real distribution needs Developer ID signing + notarization.

## Consent

Recording call audio is subject to consent laws that vary by jurisdiction. You
capture your own device as a participant, but for anything beyond personal use add
a disclosure/consent step. Not legal advice.
