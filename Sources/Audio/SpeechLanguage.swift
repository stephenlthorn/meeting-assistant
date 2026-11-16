import Foundation
import Speech

/// Which language to transcribe, and how each backend names it. Pure logic
/// over identifiers, so it can be tested without a speech model on the Mac.
enum SpeechLanguage {
    static let fallbackIdentifier = "en-US"

    /// The locale a session will use, and a notice when it is not the one that was asked for.
    struct Resolution: Equatable {
        let identifier: String
        let notice: String?
    }

    /// `en_US` and `en-US` are the same locale; supported lists use both spellings.
    static func canonical(_ identifier: String) -> String {
        Locale(identifier: identifier).identifier(.bcp47)
    }

    /// The user's current locale when the engine supports it, otherwise English (US).
    static func defaultIdentifier(supported: [String], current: Locale = .current) -> String {
        let available = Set(supported.map(canonical))
        let currentID = canonical(current.identifier)
        if available.contains(currentID) { return currentID }
        if available.contains(fallbackIdentifier) || available.isEmpty { return fallbackIdentifier }
        return supported.map(canonical).first { $0.hasPrefix("en") } ?? fallbackIdentifier
    }

    /// A saved choice that is no longer supported falls back to the default and
    /// says so. An empty `supported` list means the engine could not say, so the
    /// saved choice is trusted rather than replaced on no evidence.
    static func resolve(saved: String?, supported: [String], current: Locale = .current) -> Resolution {
        guard let saved, !saved.isEmpty else {
            return Resolution(identifier: defaultIdentifier(supported: supported, current: current), notice: nil)
        }
        let wanted = canonical(saved)
        guard !supported.isEmpty else { return Resolution(identifier: wanted, notice: nil) }
        if supported.map(canonical).contains(wanted) { return Resolution(identifier: wanted, notice: nil) }
        let used = defaultIdentifier(supported: supported, current: current)
        return Resolution(identifier: used,
                          notice: "\(displayName(wanted)) isn't available for transcription on this Mac, "
                              + "so \(displayName(used)) is being used. Pick another language in Settings.")
    }

    static func displayName(_ identifier: String, in locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// The language's name in English, for a sentence in a prompt.
    static func englishLanguageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    // MARK: - Deepgram

    /// Languages Deepgram documents for nova-3 (the monolingual list), plus the
    /// regional variants it names. Anything not here is not sent: Deepgram then
    /// assumes English, and Settings and a notice say so.
    private static let deepgramLanguages: Set<String> = [
        "en", "en-US", "en-GB", "en-AU", "en-NZ", "en-IN", "en-CA",
        "fr", "fr-CA", "de", "de-CH", "es", "es-419", "pt", "pt-BR", "pt-PT", "nl", "nl-BE",
        "zh-CN", "zh-TW", "zh-HK",
        "af", "ar", "be", "bn", "bs", "bg", "ca", "cs", "da", "el", "et", "fi", "gl", "gu", "he", "hi",
        "hr", "hu", "id", "it", "ja", "kn", "ko", "lt", "lv", "mk", "mr", "ms", "no", "fa", "pl", "ro",
        "ru", "sk", "sl", "sr", "sv", "ta", "te", "th", "tl", "tr", "uk", "vi",
    ]

    /// The `language` value for Deepgram nova-3, or nil when none can be mapped
    /// with confidence: an exact match, else the bare language of a regional variant.
    static func deepgramLanguage(for identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        let id = canonical(identifier)
        if deepgramLanguages.contains(id) { return id }
        guard let code = id.split(separator: "-").first.map(String.init) else { return nil }
        let language = ["nb": "no", "nn": "no"][code] ?? code
        return deepgramLanguages.contains(language) ? language : nil
    }

    /// The identifier Deepgram uses: an explicit choice as is (so Settings can
    /// name it even when unmapped), otherwise the current locale when Deepgram
    /// can be told about it, otherwise English (US).
    static func deepgramIdentifier(saved: String?, current: Locale = .current) -> String {
        if let saved, !saved.isEmpty { return canonical(saved) }
        let currentID = canonical(current.identifier)
        return deepgramLanguage(for: currentID) == nil ? fallbackIdentifier : currentID
    }

    // MARK: - Answer language

    /// The one sentence added to answer and summary prompts, or nil for none.
    /// "Same as the call language" names the call language only when the user
    /// picked a non-English one explicitly: on Automatic the call language is
    /// not known up front, and the model already follows the transcript.
    static func answerSentence(answerLanguage: String?, callLocale: String?) -> String? {
        if let answerLanguage, !answerLanguage.isEmpty {
            return "Answer in \(englishLanguageName(answerLanguage))."
        }
        guard let callLocale, !callLocale.isEmpty, let code = languageCode(of: callLocale), code != "en" else { return nil }
        return "Answer in \(englishLanguageName(code))."
    }

    static func languageCode(of identifier: String) -> String? {
        canonical(identifier).split(separator: "-").first.map(String.init)
    }

    // MARK: - What this Mac can transcribe

    /// Every locale the engine in use can transcribe, as canonical identifiers.
    @MainActor static func supportedIdentifiers() async -> [String] {
        if TranscriberFactory.analyzerAvailable, #available(macOS 26, *) {
            return await SpeechTranscriber.supportedLocales.map { canonical($0.identifier) }
        }
        return legacySupportedIdentifiers()
    }

    static func legacySupportedIdentifiers() -> [String] {
        SFSpeechRecognizer.supportedLocales().map { canonical($0.identifier) }.sorted()
    }

    /// Whether the on-device model for `identifier` is already installed; nil
    /// when the engine does not have downloadable models (macOS 14-15).
    @MainActor static func isModelInstalled(_ identifier: String) async -> Bool? {
        guard TranscriberFactory.analyzerAvailable, #available(macOS 26, *) else { return nil }
        let wanted = canonical(identifier)
        return await SpeechTranscriber.installedLocales.contains { canonical($0.identifier) == wanted }
    }
}
