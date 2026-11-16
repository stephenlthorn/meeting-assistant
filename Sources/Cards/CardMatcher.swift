import Foundation

/// Finds card triggers in spoken text. Triggers are normalized and indexed once,
/// when the matcher is built, so a line costs one pass over its words however
/// many cards there are; nothing is compiled per line.
///
/// Text and triggers are cut into words the same way: case, accents and
/// punctuation (apostrophes included) are ignored, so "Acme" matches "acme's"
/// and "ACME," but not "Acmeville", and a phrase matches across any run of
/// spaces or punctuation.
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
        var current = ""
        for character in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
