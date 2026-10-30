# Feature roadmap - 2026-10-30

Written after v0.3.0. M1-M7 from `2026-10-29-roadmap.md` shipped: capture health, app-only capture, saved
transcripts, Summarize Meeting, the question queue, bounded memory and the app shell. This plan is about
what makes the app worth keeping open on every call, in the order to build it.

## What the app is for

Meeting Assistant helps during a call. It is private, it never joins as a bot, it uses your own API key,
and it is MIT licensed. Granola writes notes after the call. Otter and Fireflies join as a visible bot.
Cluely sells being undetectable. The nearest thing to this app is Cluely without the hiding, plus
Granola's privacy. Every item below either makes the answer during the call better, makes the app easier
to install and keep, or turns the call into something useful afterwards.

## Rules every item follows

- **Test-first.** Keep the hostless XCTest bundle green, and keep `ma-test.sh`'s serial builds.
- **New data flows need a new terms version.** Anything that sends something new off the Mac bumps
  `termsVersion` and appears on the welcome screen and in PRIVACY.md before it ships. A local-only feature
  does not.
- **Off by default.** A new permission (Calendar, screen frames) is asked for only when the user turns on
  the feature that needs it.
- **No hidden mode, ever.** See "Not doing".

## Quick wins (any release)

- **Q1. A model list that cannot go stale.** `AppSettings.availableModels` is hardcoded and already
  behind: it offers `claude-sonnet-5` and `claude-opus-5`, and the default is `claude-haiku-4-5`. Read
  the list from the Models API (`GET /v1/models`) when a key is saved. Keep a small built-in fallback,
  and show the display names the API returns. *S.*
- **Q2. Prompt caching.** The profile prompt and the extra instructions are the same on every request.
  Mark them with `cache_control` so repeated answers cost less and start sooner. This is a prerequisite
  for N2. *S.*
- **Q3. Pick the transcription language.** `AnalyzerTranscriber` defaults to `en-US`. Add a Settings
  choice drawn from `SpeechTranscriber.supportedLocales`, plus a matching answer language. *S.*

## v0.4 - Launch follow-through

The launch posts send new people to the download, and this release removes what makes them give up.

### N1. Updates that keep your permissions
**Problem.** Every ad-hoc build has a new code identity. After each update macOS asks for Screen
Recording and Microphone again, and the Keychain asks about the API key again. Most people will stop
updating, or stop using the app.
**Shape.**
- Sign releases with one stable self-signed certificate held in the `release` environment, not ad-hoc.
  The designated requirement then stays the same from build to build, so TCC and Keychain grants should
  survive an update. Verify this on two consecutive builds before relying on it.
- Gatekeeper still blocks the first launch until the app is notarized. The real fix is a Developer ID
  certificate ($99 a year, a maintainer decision). The workflow already supports it with all six secrets.
- Add an in-app "Check for updates" that reads the GitHub Releases API, shows the release notes, and
  links to the download. Sparkle can come later, once builds are notarized.
- Publish a Homebrew cask (`brew install --cask meeting-assistant`). It also counts as a release-asset
  download.

**Done when.** Two consecutive releases install over each other with no new permission or Keychain
prompt, and the menu offers the newer version. *M.*

### N2. Instant cards
**Problem.** The most useful help on a sales call is the thing you already know but cannot find in two
seconds: a competitor one-liner, a pricing answer, a security fact. An LLM round trip takes 1.5-3 s and
can be wrong.
**Shape.** A card is a trigger phrase or phrases plus a short Markdown body that the user writes in
Settings, or imports as a folder of `.md` files. When "Them" says a trigger, the card appears in the
overlay at once, with no network and no model. Cards stack, can be dismissed, and are logged in the saved
transcript.
**Done when.** In a scripted sample call, a competitor's name shows the card in under 100 ms, and a
near-miss word does not. *M.*

### N3. Custom vocabulary
**Problem.** Product, company and people names are the words recognition gets wrong most often, and they
are the words that matter on a sales call.
**Shape.** One list in Settings feeds every backend:
- `AnalysisContext.contextualStrings` for SpeechAnalyzer. Apple caps it at 100 short phrases. It is
  documented for `DictationTranscriber`, so test whether `SpeechTranscriber` honours it before relying on it.
- `contextualStrings` for SFSpeechRecognizer.
- Deepgram's keyterms for nova-3.
- N2's card triggers are added to the list automatically.

**Done when.** A synthetic clip that misrecognises a made-up product name comes out right once the name
is on the list. *S-M.*

### N4. Follow-up email
**Problem.** After a sales call, the next step is the recap email. Summarize Meeting already has the
decisions and action items.
**Shape.** A "Draft follow-up" button in the summary window. It uses the summary, not the raw
transcript, plus the profile, and writes a short email in the user's voice (extra instructions apply).
Buttons copy it or open it in Mail. No new data flow: it is one more request built from what Summarize
already sent. *S.*

## v0.5 - Your material, your Mac

### N5. Your material
**Problem.** Answers come from Claude's general knowledge plus the transcript. On a sales call, the right
answer is in your own one-pager, pricing sheet or FAQ.
**Shape.**
- A folder in Settings, holding Markdown, text or PDF via PDFKit, up to a token budget shown in Settings.
- Its text is sent as a cached system block (Q2), so it costs full price once per cache window, not on
  every answer.
- Answers cite the file they drew from.
- No embeddings or vector store at first: a budget-capped prefix is simpler and easy to audit. Retrieval
  comes later if folders outgrow the budget.
- It is a new data flow, so it needs a terms bump and a line on the welcome screen.

**Done when.** A question whose answer is only in the folder gets that answer with the file named. *M.*

### N6. Fully local answers
**Problem.** The privacy promise stops at Claude: transcript text leaves the Mac. Some people cannot
send call content to any cloud.
**Shape.** The answering protocol (`AnthropicClient.stream(_:)`) gets two more providers:
- **Apple's on-device model** (Foundation Models, macOS 26, Apple Intelligence Macs).
  - Its context window is reported as 4,096 tokens for prompt and answer together. That is enough for a
    recent-excerpt answer, but not for a whole-call summary, so a summary is built in chunks and then
    merged.
  - Check `SystemLanguageModel.default.availability` and explain each reason it may be unavailable.
- **Any OpenAI-compatible endpoint**: Ollama and LM Studio on the Mac, and also OpenAI or OpenRouter for
  people with those keys.

Settings names the provider. The status line already shows where text goes, and it must name these too.
**Done when.** With Wi-Fi off, a sample-meeting answer streams from the on-device model, and a summary of
a 3-hour synthetic call completes in chunks. *M-L.*

### N7. Calendar-aware start
**Problem.** You open the app when the call has already started, and saved files are named by timestamp.
**Shape.** Opt-in Calendar access through EventKit, which is local only.
- When an event with a call link (Zoom, Meet, Teams, Webex) starts, the app posts a notification offering
  to start listening, using the right meeting app for M2's filter.
- The event title and attendees go into the transcript header and the file name.
- Listening stops when the meeting app quits (`didTerminateApplication` is already observed).

**Done when.** A fixture event five minutes away produces the offer at its start time, and the saved file
carries its title. *M.*

## v0.6 - After the call

### N8. Meeting library
**Problem.** Saved transcripts are files in a folder. Finding last Tuesday's call means Finder and grep.
**Shape.**
- A library window lists saved calls by date and title (from N7), with their summaries.
- Full-text search is local: SQLite FTS over the Markdown files, rebuilt from them, so the files stay the
  source of truth.
- "Ask about this call" reuses the answer path on one saved transcript.
- Asking across calls comes later, because it needs retrieval.

*M.*

### N9. Call metrics
**Problem.** Sales coaching tools charge for talk ratio and monologue length. The app already has both
sides labelled.
**Shape.** Talk-time split, the longest uninterrupted stretch per side, questions asked by each side, and
speaking pace. They are computed locally from transcript timing and shown in the summary window. An
optional overlay nudge appears after a monologue longer than a threshold you set. *S-M.*

### N10. Export where the work happens
**Shape.** The summary and action items can be copied as Markdown, as plain text, or as a checklist for
Apple Reminders through EventKit (local). Integrations that need a server or OAuth, such as CRMs and
Notion, wait for a clear demand signal from issues, and each one is opt-in. *S per target.*

## Later

- **Who said what on their side.** Label several remote speakers ("Them 1", "Them 2", renamed from N7's
  attendees). FluidAudio is an open-source Swift package that runs CoreML diarization on-device with
  streaming and offline pipelines. Measure its CPU and Neural Engine cost during a live call before
  committing to it. *L.*
- **Live translation.** Translate "Them" lines into your language beside the original, with Apple's
  Translation framework (on-device) where the pair is supported. *M.*
- **What's on the shared screen.** Opt-in Vision OCR of the meeting window's frames, so answers can see the
  slide being discussed. It is a new data flow and a sensitive one: a terms bump, off by default, and
  never kept on disk. *L.*
- **Mac App Store edition.** A sandboxed build would end Gatekeeper friction for good. It needs
  ScreenCaptureKit and global shortcuts to work inside the sandbox. *L.*

## Not doing

- **A hidden or undetectable mode.** The overlay stays an ordinary window, and the README keeps asking
  you to tell people you use an assistant. This is the line between this app and Cluely.
- **A bot that joins the call**, accounts, cloud sync or analytics. Downloads are counted from GitHub
  release assets, which needs nothing in the app.
- **An iOS app.** iOS has no system-audio capture that would make it work the same way.

## How to reorder this

After the launch, let demand move items. Check these signals weekly:
- GitHub issues and stars.
- Release downloads per version (`gh api repos/stephenlthorn/meeting-assistant/releases`).
- Which features people ask about in launch threads.

If people ask most for local answers, move N6 ahead of N2. If they ask for an easier install, Developer
ID notarization (N1) is the step that changes the most.
