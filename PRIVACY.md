# Privacy Policy

Last updated: October 29, 2026

Meeting Assistant is an open-source Mac app that transcribes your calls and asks Claude for help. The short version: the developer never receives any of your data.

## What the app captures

- The audio your Mac plays, which is the other people on a call. macOS gates this behind Screen Recording permission.
- Your microphone.

Capture only happens while you are listening; the menu bar icon shows a record symbol. The sample meeting captures nothing: it plays a scripted conversation, and what it can send is described below.

## Where your data goes

- **Your Mac.** Speech is transcribed with Apple's on-device speech recognition. On macOS 26 and later this always stays on your Mac.
- **Apple's speech servers, only if you allow it (macOS 14 and 15).** If your Mac cannot transcribe your language on-device, Meeting Assistant does not transcribe, and says so, until you separately turn on "Allow Apple's speech servers" in Settings. It is off by default and asks you to confirm. Once on, audio from both sides of your calls streams to Apple for transcription and [Apple's privacy terms](https://www.apple.com/legal/privacy/) apply. Turning it off takes effect immediately, even in the middle of a call, and so does withdrawing your agreement.
- **Anthropic (Claude).** When you ask for help, or auto-answer is on, the most recent transcript text (up to about 4,000 characters) and your profile and extra instructions are sent to Anthropic's API using your own API key. When you choose "Summarize Meeting", the **whole transcript** of the call (up to about 400,000 characters; if it is longer, the newest part) and your extra instructions are sent the same way, so the summary can cover the full call. Nothing is sent to Anthropic unless you ask for help, summarize, or leave auto-answer on. [Anthropic's privacy policy](https://www.anthropic.com/legal/privacy) applies.
- **The sample meeting.** "Try a Sample Meeting" plays a scripted sales call and records nothing. Until you agree to the terms on the welcome screen it uses canned answers and sends nothing anywhere, even if you have an Anthropic key saved. After you agree, it calls Claude only when you ask for an answer: the request carries the scripted lines, never audio or anything from a real call, to Anthropic with your own API key, and can include your profile and extra instructions like any other answer.
- **Deepgram, only if you turn it on.** After you confirm, audio from both sides of your calls streams to Deepgram for transcription using your own Deepgram key. [Deepgram's privacy policy](https://deepgram.com/privacy) applies. Turning Deepgram off, removing its key or withdrawing your agreement stops the audio immediately, even in the middle of a call.
- **No one else.** There are no analytics, no tracking, no accounts and no developer server.

## What is stored on your Mac

- Your API keys, in the macOS Keychain.
- Preferences such as model, profile, extra instructions, shortcuts and the overlay's position, and whether you agreed to the privacy terms, to Deepgram and to Apple's speech servers.
- Transcripts and answers stay in memory while the app runs and are gone when you quit, unless you copy them, save them with "Save Transcript..." in the menu, or turn on saving (below). A very long call keeps only its most recent turns in memory; Copy Transcript then starts with a note that earlier lines were trimmed.
- **Saved transcripts, only if you turn them on.** "Save transcripts" in Settings is off by default. When on, each call is written as a Markdown file with timestamps, every 30 seconds and when you stop, into `~/Library/Application Support/Meeting Assistant/Transcripts` or the folder you choose ("Show Transcripts Folder" in the menu opens it in Finder). The files are readable only by your macOS account, are never sent anywhere by Meeting Assistant, and are yours to move or delete. They stay on this Mac unless you choose a folder that syncs: macOS uploads a folder in iCloud Drive, or in Desktop or Documents while iCloud's Desktop & Documents Folders sync is on, to Apple (the app itself sends nothing), and Settings warns you when the chosen folder is one of those. The default folder is not synced. Turning it off stops saving immediately. With saving on, a summary you ask for is also saved next to the transcript, as `<transcript name>-summary.md`, and a very long call can be summarized from the whole file.

## The people you talk to

Recording and transcription laws differ by country and state, and some require every participant's consent. You are responsible for telling the people you talk to that you use an AI assistant, and for getting consent where the law requires it.

## Children

Meeting Assistant is not directed at children under 13.

## Changes

Changes to this policy are published in this file in the public repository. When the terms on the app's welcome screen change, the app asks you to agree again.

## Contact

Open an issue at https://github.com/stephenlthorn/meeting-assistant/issues or get in touch through https://stephenthorn.com.
