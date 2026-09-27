import SwiftUI

/// First-run screen: what the app listens to, where the data goes, and a
/// reminder about the other people on the call. Listening waits for "Agree".
struct WelcomeView: View {
    let onTrySample: () -> Void
    let onAgree: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Meeting Assistant")
                        .font(.title2.bold())
                    Text("Live help from Claude during your calls, transcribed on your Mac.")
                        .foregroundStyle(.secondary)
                }
            }
            WelcomeSection(symbol: "ear", title: "What it listens to",
                           text: "The other people on your call (your Mac's sound output, which needs Screen Recording permission) and your microphone.")
            WelcomeSection(symbol: "lock.shield", title: "Where your data goes",
                           text: "Speech is transcribed on this Mac. When you ask for help, or auto-answer is on, the last few minutes of transcript text go to Anthropic's Claude using your own API key. If you turn on Deepgram, call audio streams to Deepgram instead. Nothing is sent to the developer.")
            WelcomeSection(symbol: "person.2", title: "The people you talk to",
                           text: "Recording and transcription laws vary, and some places require everyone's consent. Let people know you use an AI assistant.")
            HStack {
                Link("Privacy policy", destination: AppLinks.privacyPolicy)
                Spacer()
                Button("Try a Sample Meeting", action: onTrySample)
                Button("Agree and Continue", action: onAgree)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

private struct WelcomeSection: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
