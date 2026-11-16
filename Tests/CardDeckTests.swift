import XCTest

final class CardDeckTests: XCTestCase {
    private func card(_ id: String) -> Card { Card(id: id, title: id, triggers: [id], body: "b") }
    private let start = Date(timeIntervalSince1970: 1_000)

    func testANewCardIsShownOnTopOfTheOlderOnes() {
        var deck = CardDeck()
        _ = deck.show([card("a")], at: start)
        _ = deck.show([card("b")], at: start)

        XCTAssertEqual(deck.displayed.map(\.id), ["b", "a"])
    }

    func testACardAlreadyVisibleIsNotShownAgain() {
        var deck = CardDeck()
        XCTAssertEqual(deck.show([card("a")], at: start).map(\.id), ["a"])
        XCTAssertEqual(deck.show([card("a")], at: start.addingTimeInterval(500)).map(\.id), [])
        XCTAssertEqual(deck.displayed.map(\.id), ["a"])
    }

    func testADismissedCardStaysAwayForSixtySecondsThenCanReturn() {
        var deck = CardDeck()
        _ = deck.show([card("a")], at: start)
        deck.dismiss(id: "a")

        XCTAssertEqual(deck.show([card("a")], at: start.addingTimeInterval(59)).map(\.id), [])
        XCTAssertEqual(deck.show([card("a")], at: start.addingTimeInterval(60)).map(\.id), ["a"])
    }

    func testOnlyThreeCardsAreDisplayedAndTheRestAreCounted() {
        var deck = CardDeck()
        for id in ["a", "b", "c", "d", "e"] { _ = deck.show([card(id)], at: start) }

        XCTAssertEqual(deck.displayed.map(\.id), ["e", "d", "c"])
        XCTAssertEqual(deck.hiddenCount, 2)

        deck.dismiss(id: "e")
        XCTAssertEqual(deck.displayed.map(\.id), ["d", "c", "b"])
        XCTAssertEqual(deck.hiddenCount, 1)
    }

    func testClearingForgetsTheCardsAndTheCooldown() {
        var deck = CardDeck()
        _ = deck.show([card("a")], at: start)

        deck.clear()

        XCTAssertEqual(deck.displayed, [])
        XCTAssertEqual(deck.show([card("a")], at: start.addingTimeInterval(1)).map(\.id), ["a"])
    }
}
