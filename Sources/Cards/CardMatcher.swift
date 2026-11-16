import Foundation
import NaturalLanguage

/// Finds card triggers in spoken text. Triggers are normalized and indexed once,
/// when the matcher is built, so a line costs one pass over its words however
/// many cards there are; nothing is compiled per line.
///
/// Text and triggers are cut into words the same way: case, accents and
/// punctuation (apostrophes included) are ignored, so "Acme" matches "acme's"
/// and "ACME," but not "Acmeville", and a phrase matches across any run of
/// spaces or punctuation. Japanese, Chinese, Thai and other languages written
/// without spaces are cut into words by the system's segmenter.
struct CardMatcher {
    private struct Entry {
        let card: Int
        let rest: [String]
    }

    private let cards: [Card]
    private let byFirstWord: [String: [Entry]]

    init(cards: [Card]) {
        self.cards = cards
        var index: [String: [Entry]] = [:]
        for (position, card) in cards.enumerated() {
            for trigger in card.triggers {
                let words = Self.words(in: trigger)
                guard let first = words.first else { continue }
                index[first, default: []].append(Entry(card: position, rest: Array(words.dropFirst())))
            }
        }
        byFirstWord = index
    }

    var isEmpty: Bool { byFirstWord.isEmpty }

    /// The cards whose triggers appear in `text`, in the order they were said.
    func matches(in text: String) -> [Card] {
        guard !byFirstWord.isEmpty else { return [] }
        let spoken = Self.words(in: text)
        var firstSeen: [Int: Int] = [:]
        for (position, word) in spoken.enumerated() {
            guard let entries = byFirstWord[word] else { continue }
            for entry in entries where firstSeen[entry.card] == nil {
                if Self.follows(entry.rest, in: spoken, after: position) { firstSeen[entry.card] = position }
            }
        }
        return firstSeen.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.map { cards[$0.key] }
    }

    private static func follows(_ rest: [String], in spoken: [String], after position: Int) -> Bool {
        guard position + rest.count < spoken.count else { return false }
        for (offset, word) in rest.enumerated() where spoken[position + 1 + offset] != word { return false }
        return true
    }

    static func words(in text: String) -> [String] {
        var words: [String] = []
        var run = ""
        var tokenizer: NLTokenizer?
        func flush() {
            guard !run.isEmpty else { return }
            defer { run = "" }
            guard run.unicodeScalars.contains(where: isWrittenWithoutSpaces) else {
                words.append(run.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
                return
            }
            let shared = tokenizer ?? NLTokenizer(unit: .word)
            tokenizer = shared
            words += segments(of: run, with: shared)
        }
        for character in text {
            if character.isLetter || character.isNumber {
                run.append(character)
            } else {
                flush()
            }
        }
        flush()
        return words
    }

    /// A run of letters in a script with no spaces between words is cut with the
    /// system's word segmenter, since the spoken sentence and the trigger must be
    /// cut the same way for a trigger inside a sentence to be found. Kana keeps its
    /// voicing marks (no diacritic folding): they tell different words apart.
    private static func segments(of run: String, with tokenizer: NLTokenizer) -> [String] {
        tokenizer.string = run
        var segments: [String] = []
        tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { range, _ in
            segments.append(run[range].lowercased())
            return true
        }
        return segments
    }

    private static func isWrittenWithoutSpaces(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F, // Hiragana, Katakana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, // Han
             0x0E00...0x0EFF, // Thai, Lao
             0x1000...0x109F, 0x1780...0x17FF: // Myanmar, Khmer
            return true
        default:
            return false
        }
    }
}
