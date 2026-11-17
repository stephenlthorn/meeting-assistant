import XCTest

final class CardFolderTests: XCTestCase {
    private func parse(_ text: String, file: String = "note.md") -> Result<Card, CardFile.Skipped> {
        CardFile.parse(text, file: file)
    }

    func testTheFirstHeadingIsTheTitleTriggersAreListedAndTheRestIsTheBody() throws {
        let card = try parse("""
            # Acme one-liner

            Triggers: Acme, acme corp , ACME Inc

            - Cheaper per seat
            - Weak on **security**
            """).get()

        XCTAssertEqual(card.title, "Acme one-liner")
        XCTAssertEqual(card.triggers, ["Acme", "acme corp", "ACME Inc"])
        XCTAssertEqual(card.body, "- Cheaper per seat\n- Weak on **security**")
        XCTAssertEqual(card.id, "file:note.md")
        XCTAssertTrue(card.isEnabled)
    }

    func testTheTriggersLineMayComeBeforeTheHeadingAndWindowsLineEndingsWork() throws {
        let card = try parse("Triggers: soc 2\r\n# Security\r\nWe are SOC 2 Type II.\r\n").get()

        XCTAssertEqual(card.title, "Security")
        XCTAssertEqual(card.triggers, ["soc 2"])
        XCTAssertEqual(card.body, "We are SOC 2 Type II.")
    }

    func testAFileWithoutAHeadingIsSkippedWithAReason() {
        guard case .failure(let skipped) = parse("Triggers: a\n\nBody only.") else { return XCTFail("should be skipped") }
        XCTAssertEqual(skipped, CardFile.Skipped(file: "note.md", reason: "no '# Heading' line for the title"))
    }

    func testAFileWithoutTriggersIsSkippedWithAReason() {
        guard case .failure(let skipped) = parse("# Title\n\nBody.") else { return XCTFail("should be skipped") }
        XCTAssertEqual(skipped.reason, "no 'Triggers: a, b, c' line")
    }

    func testATriggersLineWithNothingUsableIsSkipped() {
        guard case .failure(let skipped) = parse("# Title\nTriggers: , ... ,\nBody.") else { return XCTFail("should be skipped") }
        XCTAssertEqual(skipped.reason, "the Triggers line has no usable phrase")
    }

    func testAFileWithNoBodyIsSkipped() {
        guard case .failure(let skipped) = parse("# Title\nTriggers: a\n\n") else { return XCTFail("should be skipped") }
        XCTAssertEqual(skipped.reason, "no body text")
    }

    func testAFolderLoadsGoodCardsAndReportsTheBadOnesWithoutStopping() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try "# Good\nTriggers: good\nGood body.".write(to: folder.appendingPathComponent("good.md"), atomically: true, encoding: .utf8)
        try "just words".write(to: folder.appendingPathComponent("bad.md"), atomically: true, encoding: .utf8)
        try "# Not markdown\nTriggers: x\nBody".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try Data([0xFF, 0xFE, 0x00]).write(to: folder.appendingPathComponent("binary.md"))

        let loaded = CardFolder.load(folder)

        XCTAssertEqual(loaded.cards.map(\.title), ["Good"])
        XCTAssertEqual(loaded.skipped.map(\.file), ["bad.md", "binary.md"])
        XCTAssertNil(loaded.folderError)
    }

    func testAMissingFolderSaysSoInsteadOfLoadingNothingQuietly() {
        let loaded = CardFolder.load(URL(fileURLWithPath: "/nonexistent/cards-\(UUID().uuidString)"))

        XCTAssertTrue(loaded.cards.isEmpty)
        XCTAssertNotNil(loaded.folderError)
    }
}
