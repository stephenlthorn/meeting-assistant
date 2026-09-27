# Privacy Policy

Last updated: September 27, 2026

Meeting Assistant is an open-source Mac app that transcribes your calls and asks Claude for help. The short version: the developer never receives any of your data.

## What the app captures

- The audio your Mac plays, which is the other people on a call. macOS gates this behind Screen Recording permission.
- Your microphone.

Capture only happens while you are listening; the menu bar icon shows a record symbol. The sample meeting captures nothing.

## Where your data goes

- **Your Mac.** Speech is transcribed with Apple's on-device speech recognition. On macOS 14 and 15, if on-device recognition is not available for your language, Apple's speech service is used instead and the app tells you so.
- **Anthropic (Claude).** When you ask for help, or auto-answer is on, the most recent transcript text (up to about 4,000 characters) and your profile and extra instructions are sent to Anthropic's API using your own API key. [Anthropic's privacy policy](https://www.anthropic.com/legal/privacy) applies.
- **Deepgram, only if you turn it on.** After you confirm, audio from both sides of your calls streams to Deepgram for transcription using your own Deepgram key. [Deepgram's privacy policy](https://deepgram.com/privacy) applies.
- **No one else.** There are no analytics, no tracking, no accounts and no developer server.

## What is stored on your Mac

- Your API keys, in the macOS Keychain.
- Preferences such as model, profile, extra instructions, shortcuts and the overlay's position.
- Transcripts and answers stay in memory while the app runs and are gone when you quit, unless you copy them.

## The people you talk to

Recording and transcription laws differ by country and state, and some require every participant's consent. You are responsible for telling the people you talk to that you use an AI assistant, and for getting consent where the law requires it.

## Children

Meeting Assistant is not directed at children under 13.

## Changes

Changes to this policy are published in this file in the public repository. When the terms on the app's welcome screen change, the app asks you to agree again.

## Contact

Open an issue at https://github.com/stephenlthorn/meeting-assistant/issues or get in touch through https://stephenthorn.com.
