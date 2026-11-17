import Foundation

/// What the controller needs for instant cards in one value: the deck on
/// screen and the matcher for the call in progress. A live call matches the
/// user's active cards (rebuilt only when they change); the sample meeting
/// matches its own built-in cards and nothing of the user's.
@MainActor
struct InstantCards {
    private var deck = CardDeck()
    private var matcher = CardMatcher(cards: [])
    private var builtFrom: Int?
    private var sample: CardMatcher?

    var displayed: [Card] { deck.displayed }
    var hiddenCount: Int { deck.hiddenCount }

    mutating func useSampleCards(_ cards: [Card]) {
        sample = CardMatcher(cards: cards)
    }

    mutating func useUserCards() {
        sample = nil
    }

    /// Looks for triggers in what was just heard; returns the cards that appeared.
    mutating func hear(_ text: String, store: CardStore, at time: Date) -> [Card] {
        let hits = currentMatcher(store: store).matches(in: text)
        guard !hits.isEmpty else { return [] }
        return deck.show(hits, at: time)
    }

    mutating func dismiss(id: String) {
        deck.dismiss(id: id)
    }

    mutating func clear() {
        deck.clear()
    }

    private mutating func currentMatcher(store: CardStore) -> CardMatcher {
        if let sample { return sample }
        if builtFrom != store.revision {
            matcher = CardMatcher(cards: store.activeCards)
            builtFrom = store.revision
        }
        return matcher
    }
}
