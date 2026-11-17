import XCTest

final class CardMatcherTests: XCTestCase {
    private func card(_ id: String, _ triggers: String...) -> Card {
        Card(id: id, title: id, triggers: triggers, body: "body")
    }

    private func hits(_ text: String, _ cards: [Card]) -> [String] {
        CardMatcher(cards: cards).matches(in: text).map(\.id)
    }

    func testAWholeWordMatchesWhateverItsCase() {
        XCTAssertEqual(hits("We also looked at ACME last week.", [card("a", "Acme")]), ["a"])
    }

    func testAPossessiveStillMatchesTheName() {
        XCTAssertEqual(hits("Acme's pricing is higher.", [card("a", "acme")]), ["a"])
        XCTAssertEqual(hits("Acme\u{2019}s pricing is higher.", [card("a", "acme")]), ["a"])
    }

    func testANearMissWordDoesNotMatch() {
        XCTAssertEqual(hits("We drove through Acmeville.", [card("a", "acme")]), [])
        XCTAssertEqual(hits("Acm is not acme.", [card("a", "acm")]), ["a"])
        XCTAssertEqual(hits("The rollouts went fine.", [card("a", "rollout")]), [])
    }

    func testAPhraseMatchesAcrossWhitespaceAndPunctuation() {
        let cards = [card("p", "per seat pricing")]
        XCTAssertEqual(hits("What is your per   seat\npricing?", cards), ["p"])
        XCTAssertEqual(hits("What is your per-seat pricing?", cards), ["p"])
        XCTAssertEqual(hits("pricing per seat", cards), [])
    }

    func testApostrophesInATriggerAreNormalizedToo() {
        let cards = [card("d", "don't have a budget")]
        XCTAssertEqual(hits("Honestly we don\u{2019}t have a budget.", cards), ["d"])
        XCTAssertEqual(hits("Honestly we don't have a budget.", cards), ["d"])
    }

    func testAccentsAreIgnored() {
        XCTAssertEqual(hits("Our cafe is open.", [card("c", "café")]), ["c"])
    }

    func testEveryTriggerOfACardWorksAndTheCardIsReportedOnce() {
        let cards = [card("s", "soc 2", "security review")]
        XCTAssertEqual(hits("Do you have SOC 2? We also need a security review.", cards), ["s"])
        XCTAssertEqual(hits("a security review", cards), ["s"])
    }

    func testSeveralCardsComeBackInTheOrderTheirWordsWereSaid() {
        let cards = [card("a", "alpha"), card("b", "beta")]
        XCTAssertEqual(hits("beta then alpha", cards), ["b", "a"])
    }

    func testBlankAndPunctuationOnlyTriggersNeverMatch() {
        XCTAssertEqual(hits("anything at all, really.", [card("x", "", "  ", "...")]), [])
    }

    func testNoCardsMatchNothing() {
        XCTAssertEqual(hits("whatever", []), [])
    }

    // MARK: - Languages written without spaces

    func testAJapaneseTriggerInsideASentenceFires() {
        let cards = [card("j", "価格")]
        XCTAssertEqual(hits("この製品の価格はいくらですか。", cards), ["j"])
        XCTAssertEqual(hits("この製品は安いです。", cards), [])
    }

    func testAMultiWordJapaneseTriggerFires() {
        XCTAssertEqual(hits("すみません、製品の価格を教えてください。", [card("j", "製品の価格")]), ["j"])
    }

    func testAChineseTriggerInsideASentenceFires() {
        let cards = [card("z", "价格")]
        XCTAssertEqual(hits("我们想了解一下价格方案。", cards), ["z"])
        XCTAssertEqual(hits("我们想了解一下方案。", cards), [])
    }

    func testAThaiTriggerInsideASentenceFires() {
        XCTAssertEqual(hits("สินค้านี้ราคาเท่าไหร่", [card("t", "ราคา")]), ["t"])
    }

    func testAnEnglishTriggerStillFiresInsideAJapaneseSentence() {
        XCTAssertEqual(hits("次のAcmeの料金を見ましょう。", [card("a", "Acme")]), ["a"])
        XCTAssertEqual(hits("Acmevilleの話です。", [card("a", "Acme")]), [])
    }

    func testHundredsOfCardsStillFindTheOneThatMatches() {
        var cards = (0..<600).map { card("c\($0)", "topic\($0) detail") }
        cards.append(card("target", "voicemail"))
        let matcher = CardMatcher(cards: cards)

        XCTAssertEqual(matcher.matches(in: "most of it goes to voicemail honestly").map(\.id), ["target"])
        XCTAssertEqual(matcher.matches(in: "topic5 detail and topic599 detail").map(\.id), ["c5", "c599"])
    }
}
