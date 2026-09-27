# Contributing

Thanks for helping out. A few notes:

- **Build:** run `./scripts/bootstrap.sh` (or `xcodegen generate`) and run the MeetingAssistant scheme in Xcode.
- **Test:** `xcodebuild test -project MeetingAssistant.xcodeproj -scheme MeetingAssistant -destination 'platform=macOS'`.
  Every change comes with a test. Behavior is tested through the real types, with fakes only at system
  boundaries (audio capture, speech engines, WebSockets, HTTP); see `Tests/Support/Fakes.swift`.
- **Keep the privacy promise.** Nothing may leave the Mac except what the welcome screen describes:
  transcript excerpts to Anthropic, and audio to Deepgram when the user turns it on. If a change sends
  anything new anywhere, update the welcome screen, bump `AppSettings.termsVersion` and update `PRIVACY.md`.
- **Style:** match the surrounding code, keep types small and focused, and explain why rather than what
  in comments.
- For larger changes, please open an issue first so we can agree on the approach.
