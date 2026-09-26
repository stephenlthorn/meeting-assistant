# Meeting Assistant (macOS)

A native macOS menu-bar app that listens to your Mac's **system audio** (the other
people on a Zoom / Meet / Teams call) **and** your microphone, transcribes both
**on-device** in real time, and on a hotkey sends the recent transcript to Claude
for concise, live help in a floating overlay only on your screen.

CI tests and builds every push on macOS 26 (universal arm64 + x86_64) and
publishes a downloadable `.app` for each release.

## What it does

```
system audio (ScreenCaptureKit)  -> "Them" transcriber -\
microphone (AVAudioEngine)       -> "You"  transcriber -/
      -> merged, speaker-labeled transcript
      -> [⌘⇧Space] -> Claude Messages API (streaming)
      -> floating overlay (local, non-activating)
```

## Features

- Two-sided transcription: system audio (them) + microphone (you), merged into
  one speaker-labeled transcript in the order people spoke.
- On-device STT: SpeechAnalyzer on macOS 26+, SFSpeechRecognizer on 14–15.
- Optional **Deepgram** cloud STT for the hardest audio (opt-in in Settings). It
  keeps the stream alive through silences and reconnects if the connection drops.
- Live Claude answers in a floating overlay, streamed token by token, with a
  copy button.
- **Auto-answer** when the other side asks a question. It never interrupts an
  answer in progress.
- Echo suppression: on speakers your mic also hears the other side, so "You"
  lines that repeat what they just said are hidden.
- **Settings** (menu bar icon, then Settings…): API key in the macOS Keychain,
  model picker (Haiku / Sonnet / Opus), profile, extra instructions, shortcuts,
  and links to the privacy permissions.
- Global shortcuts, changeable in Settings: ⌘⇧Space to answer, ⌘⇧H to show or
  hide the overlay. The overlay remembers where you dragged it.

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

Select the **MeetingAssistant** scheme and Run (⌘R). The app has no Dock icon and
no app menu: click the waveform icon in the menu bar and choose **Settings…** to
paste your Anthropic API key (stored in the Keychain).

Run the tests:

```bash
xcodegen generate
xcodebuild test -project MeetingAssistant.xcodeproj -scheme MeetingAssistant -destination 'platform=macOS'
```

### Where the API key comes from

Checked in this order; Settings shows which one is in use.

1. The Keychain (saved from Settings).
2. The `ANTHROPIC_API_KEY` environment variable. Only an app started from Terminal
   or Xcode sees your shell's environment; opened from Finder, it does not.
3. `~/.config/meeting-assistant/anthropic_key`, which works however the app is launched.

The Deepgram key comes from the Keychain, then `DEEPGRAM_API_KEY`.

## Download a prebuilt app

Grab `MeetingAssistant.app.zip` from the latest [Release](../../releases/latest),
or from the **Actions** tab (latest `build` run > Artifacts). Unless the repository
has Developer ID secrets set up (see [Releasing](#releasing)), builds are ad-hoc
signed and not notarized, so clear quarantine before first launch:

```bash
unzip MeetingAssistant.app.zip
xattr -dr com.apple.quarantine MeetingAssistant.app
open MeetingAssistant.app
```

An ad-hoc build has a new code identity every release, so macOS asks for Screen
Recording and Microphone again after each update, and the Keychain asks once
before the app can read your saved key.

## Permissions

- **Screen Recording** captures the other side's audio (ScreenCaptureKit needs it
  even for audio only). macOS asks the first time you Start Listening; after
  allowing it, quit and reopen the app.
- **Microphone** captures your side. Deny it and the app transcribes their side only.
- **Speech Recognition** is needed on macOS 14–15 only; SpeechAnalyzer on macOS 26
  runs without it.

When a permission is missing, the overlay says so with an **Open Settings** button
for the right privacy pane.

## Speech-to-text

On-device is the default (private, free, offline). The first run on macOS 26
downloads the speech model; the overlay shows that while it happens. For the
hardest audio, enable **Deepgram** in Settings and paste a Deepgram key; call
audio is then streamed to Deepgram. Speaker labels come from the mic/system split,
not diarization, so headphones give the cleanest "You" transcript.

## File map

| File | Responsibility |
|------|----------------|
| `Sources/App/AssistantController.swift` | Session lifecycle, transcript, answers, auto-answer |
| `Sources/App/TranscriberSlot.swift` | Hands audio from capture threads to the current transcriber |
| `Sources/App/Problem.swift` | Problems shown to the user and the privacy pane that fixes each |
| `Sources/App/MeetingAssistantApp.swift` | App entry, menu bar, Settings scene, overlay and shortcuts |
| `Sources/Audio/CaptureInterfaces.swift` | Capture protocols and threading helpers |
| `Sources/Audio/SystemAudioCapture.swift` | ScreenCaptureKit system-audio capture (them) |
| `Sources/Audio/MicCapture.swift` | AVAudioEngine microphone capture (you), restarts on device changes |
| `Sources/Audio/AudioMath.swift` | Level and mono-mix helpers |
| `Sources/Audio/LiveTranscriber.swift` | Transcriber protocol + backend factory |
| `Sources/Audio/AnalyzerTranscriber.swift` | macOS 26+ SpeechAnalyzer backend |
| `Sources/Audio/LegacySpeechTranscriber.swift` | macOS 14–15 SFSpeechRecognizer backend |
| `Sources/Audio/CloudTranscriber.swift` | Optional Deepgram cloud STT (WebSocket) |
| `Sources/Transcript/Transcript.swift` | Merged, speaker-labeled transcript |
| `Sources/Transcript/QuestionDetector.swift` / `EchoDetector.swift` | Auto-answer trigger / echo suppression |
| `Sources/LLM/AnthropicClient.swift` | Streaming Claude Messages API client |
| `Sources/LLM/Profiles.swift` | Per-use-case system prompts |
| `Sources/UI/OverlayPanel.swift` / `OverlayView.swift` / `OverlayText.swift` | Floating overlay |
| `Sources/UI/SettingsView.swift` | Preferences window |
| `Sources/UI/Clipboard.swift` | Copy helper |
| `Sources/System/AppSettings.swift` / `KeychainStore.swift` | Settings + Keychain |
| `Sources/System/HotKeyManager.swift` / `HotKeyBinder.swift` | Global shortcuts (Carbon) |
| `Config/MeetingAssistant.entitlements` | Hardened-runtime microphone entitlement |
| `Tests/` | Unit tests (a hostless XCTest bundle over the app sources) |

## Releasing

Bump `VERSION` (for example `v0.2.0`) on `main` and push. The release workflow
tests, builds, signs and publishes it, and never re-publishes an existing tag. To
ship signed and notarized builds, add these repository secrets; without them
releases are ad-hoc signed:

| Secret | Value |
|--------|-------|
| `MACOS_CERTIFICATE_P12` | Base64 of a Developer ID Application certificate (.p12) |
| `MACOS_CERTIFICATE_PASSWORD` | Its export password |
| `MACOS_SIGNING_IDENTITY` | For example `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | For notarization (an app-specific password) |

## Notes

- **Latency**: ~1.5–3s speech-to-answer, dominated by model choice; Haiku is fastest.
- **Screen sharing**: the overlay is a local window, invisible to the other side
  when you are not screen sharing. `sharingType = .none` does not hide it from
  ScreenCaptureKit-based full-screen shares on macOS 15+.
- **Signing**: the app uses the hardened runtime with the microphone entitlement,
  without the App Sandbox.

## Consent

Recording call audio is subject to consent laws that vary by jurisdiction. You
capture your own device as a participant, but for anything beyond personal use add
a disclosure/consent step. Not legal advice.
