import SwiftUI

/// Settings for the call language and the language answers are written in.
/// The list of languages is what this Mac's speech engine can transcribe, so a
/// choice is never one that cannot work (a saved choice that has since become
/// unsupported is shown as such, and falls back with a notice when listening).
struct LanguageSection: View {
    @ObservedObject var settings: AppSettings
    @State private var supported: [String] = []
    @State private var modelInstalled: Bool?

    private var current: String? { settings.speechLocaleIdentifier.map(SpeechLanguage.canonical) }
    private var automaticName: String {
        SpeechLanguage.displayName(SpeechLanguage.defaultIdentifier(supported: supported))
    }

    var body: some View {
        Section("Language") {
            Picker("Call language", selection: $settings.speechLocaleIdentifier) {
                Text("Automatic (\(automaticName))").tag(String?.none)
                ForEach(choices, id: \.self) { id in
                    Text(label(for: id)).tag(String?.some(id))
                }
            }
            if let current, !supported.isEmpty, !supported.contains(current) {
                Text("\(SpeechLanguage.displayName(current)) isn't available for transcription on this Mac, so \(automaticName) will be used.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if modelInstalled == false {
                Text("This language's on-device speech model isn't downloaded yet. It downloads when you next start listening, which needs an internet connection the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if settings.useCloudSTT, let id = current ?? Optional(SpeechLanguage.deepgramIdentifier(saved: nil)),
               SpeechLanguage.deepgramLanguage(for: id) == nil {
                Text("Deepgram has no setting for this language, so while Deepgram is on it will assume English.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Picker("Answer in", selection: $settings.answerLanguage) {
                Text("Same as the call language").tag(String?.none)
                ForEach(answerChoices, id: \.self) { code in
                    Text(SpeechLanguage.displayName(code)).tag(String?.some(code))
                }
            }
            Text(settings.speechSessionActive
                 ? "Language changes apply when you next start listening."
                 : "The call language applies from the next time you start listening. Answers and summaries use the answer language right away.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { supported = await SpeechLanguage.supportedIdentifiers() }
        .task(id: settings.speechLocaleIdentifier) { await refreshModelState() }
    }

    /// The supported languages, plus a saved one that no longer is, so the picker never goes blank.
    private var choices: [String] {
        let saved = current.map { [$0] } ?? []
        let all = Set(supported).union(saved)
        return all.sorted { label(for: $0).localizedCaseInsensitiveCompare(label(for: $1)) == .orderedAscending }
    }

    private var answerChoices: [String] {
        let codes = Set(supported.compactMap(SpeechLanguage.languageCode(of:)))
            .union(settings.answerLanguage.map { [$0] } ?? [])
        return codes.sorted { SpeechLanguage.displayName($0).localizedCaseInsensitiveCompare(SpeechLanguage.displayName($1)) == .orderedAscending }
    }

    private func label(for id: String) -> String {
        let name = SpeechLanguage.displayName(id)
        return !supported.isEmpty && !supported.contains(id) ? "\(name) (unavailable)" : name
    }

    private func refreshModelState() async {
        let id = SpeechLanguage.resolve(saved: settings.speechLocaleIdentifier, supported: supported).identifier
        modelInstalled = await SpeechLanguage.isModelInstalled(id)
    }
}
