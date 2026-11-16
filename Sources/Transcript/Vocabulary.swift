import Foundation

/// The user's custom vocabulary: names, products and jargon the speech
/// recognizer should favour. One list feeds every backend (SpeechAnalyzer,
/// SFSpeechRecognizer, Deepgram), so it is normalised in one place.
///
/// Apple caps contextual strings at 100 phrases and recommends one or two
/// words each, so the same limits apply everywhere; longer phrases are flagged
/// in Settings, not refused.
enum Vocabulary {
    static let maximumPhrases = 100
    static let recommendedWords = 2

    /// What Settings shows about a vocabulary text.
    struct Analysis: Equatable {
        /// The phrases that will be used: trimmed, distinct, at most `maximumPhrases`.
        let phrases: [String]
        /// Distinct phrases typed, including any past the cap.
        let distinctCount: Int
        /// Phrases beyond the cap, which no backend will see.
        var ignoredCount: Int { distinctCount - phrases.count }
        /// Used phrases longer than the recommended length.
        let longPhrases: [String]
    }

    static func analyze(_ text: String) -> Analysis {
        let distinct = distinctPhrases(in: text.components(separatedBy: .newlines))
        let used = Array(distinct.prefix(maximumPhrases))
        return Analysis(phrases: used, distinctCount: distinct.count, longPhrases: used.filter(isLong))
    }

    /// One phrase per line, trimmed, repeats (ignoring case) dropped, capped.
    static func normalize(_ text: String) -> [String] { analyze(text).phrases }

    /// The user's terms first, then `extra` terms (for example another feature's
    /// trigger phrases) in whatever room the cap leaves, so the user's own
    /// words always win.
    static func effective(user: [String], extra: [String]) -> [String] {
        let combined = distinctPhrases(in: user.prefix(maximumPhrases).map { $0 } + extra)
        return Array(combined.prefix(maximumPhrases))
    }

    private static func distinctPhrases(in lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.compactMap { line -> String? in
            let phrase = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !phrase.isEmpty, seen.insert(phrase.lowercased()).inserted else { return nil }
            return phrase
        }
    }

    private static func isLong(_ phrase: String) -> Bool {
        phrase.split(separator: " ").count > recommendedWords
    }
}
