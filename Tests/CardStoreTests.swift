import XCTest

@MainActor
final class CardStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "CardStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func card(_ title: String, _ triggers: String..., enabled: Bool = true) -> Card {
        Card(title: title, triggers: triggers, body: "body", isEnabled: enabled)
    }

    func testCardsSurviveARestart() {
        let defaults = makeDefaults()
        let first = CardStore(defaults: defaults)
        first.add(card("Pricing", "price", "pricing"))

        let second = CardStore(defaults: defaults)

        XCTAssertEqual(second.userCards.map(\.title), ["Pricing"])
        XCTAssertEqual(second.userCards.first?.triggers, ["price", "pricing"])
    }

    func testACardCanBeEditedDisabledAndDeleted() throws {
        let store = CardStore(defaults: makeDefaults())
        var pricing = card("Pricing", "price")
        store.add(pricing)

        pricing.title = "Pricing answer"
        store.update(pricing)
        XCTAssertEqual(store.userCards.map(\.title), ["Pricing answer"])

        store.setEnabled(false, id: pricing.id)
        XCTAssertEqual(store.activeCards, [])

        store.delete(id: pricing.id)
        XCTAssertEqual(store.userCards, [])
    }

    func testTriggerPhrasesListEnabledCardsOnlyWithoutDuplicates() {
        let store = CardStore(defaults: makeDefaults())
        store.add(card("A", "alpha", "Beta"))
        store.add(card("B", "beta", "gamma"))
        store.add(card("Off", "delta", enabled: false))

        XCTAssertEqual(store.triggerPhrases, ["alpha", "Beta", "gamma"])
    }

    func testEveryChangeBumpsTheRevisionSoAMatcherKnowsToRebuild() {
        let store = CardStore(defaults: makeDefaults())
        let before = store.revision

        store.add(card("A", "alpha"))

        XCTAssertGreaterThan(store.revision, before)
    }

    func testFolderCardsJoinTheActiveCardsAndTheTriggerList() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try "# Folder card\nTriggers: from folder\nBody".write(to: folder.appendingPathComponent("a.md"),
                                                               atomically: true, encoding: .utf8)
        let store = CardStore(defaults: makeDefaults())
        store.add(card("Mine", "mine"))

        store.reloadFolder(folder)

        XCTAssertEqual(store.activeCards.map(\.title), ["Mine", "Folder card"])
        XCTAssertEqual(store.triggerPhrases, ["mine", "from folder"])

        store.reloadFolder(nil)
        XCTAssertEqual(store.activeCards.map(\.title), ["Mine"])
    }

    func testFolderCardsAreNeverWrittenIntoTheSavedCards() throws {
        let defaults = makeDefaults()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try "# Folder card\nTriggers: x\nBody".write(to: folder.appendingPathComponent("a.md"),
                                                    atomically: true, encoding: .utf8)
        let store = CardStore(defaults: defaults)
        store.reloadFolder(folder)
        store.add(card("Mine", "mine"))

        XCTAssertEqual(CardStore(defaults: defaults).userCards.map(\.title), ["Mine"])
    }
}
