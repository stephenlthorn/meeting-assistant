import Foundation

/// The cards currently on screen and the rules for bringing one back: never
/// while it is visible, and not within a minute of when it last appeared, even
/// if it was dismissed in between (the same phrase is often said twice in a row).
/// Time is passed in, so a test needs no waiting.
struct CardDeck {
    static let cooldown: TimeInterval = 60
    /// How many cards the overlay stacks; older ones wait behind them.
    static let displayLimit = 3

    /// Every card not dismissed yet, newest first.
    private(set) var visible: [Card] = []
    private var lastShown: [String: Date] = [:]

    var displayed: [Card] { Array(visible.prefix(Self.displayLimit)) }
    var hiddenCount: Int { max(0, visible.count - Self.displayLimit) }

    /// Puts the candidates on top, the last one on the very top. Returns the
    /// ones that were actually shown.
    @discardableResult
    mutating func show(_ candidates: [Card], at time: Date) -> [Card] {
        var shown: [Card] = []
        for card in candidates {
            guard !visible.contains(where: { $0.id == card.id }) else { continue }
            if let last = lastShown[card.id], time.timeIntervalSince(last) < Self.cooldown { continue }
            visible.insert(card, at: 0)
            lastShown[card.id] = time
            shown.append(card)
        }
        return shown
    }

    mutating func dismiss(id: String) {
        visible.removeAll { $0.id == id }
    }

    /// Clear Transcript, or a new call: the slate is wiped, cooldowns included.
    mutating func clear() {
        visible = []
        lastShown = [:]
    }
}
