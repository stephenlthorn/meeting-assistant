import XCTest

/// Instant cards fire on what the recognizer writes, so a trigger phrase it cannot spell
/// never fires. The session's transcriber therefore gets the active cards' triggers as
/// extra vocabulary, behind the user's own terms.
@MainActor
final class CardVocabularyWiringTests: XCTestCase {
    private var originalAnalyzerAvailability = TranscriberFactory.analyzerAvailable
    private var originalLegacyLocales = TranscriberFactory.legacySupportedLocales

    override func setUp() async throws {
        originalAnalyzerAvailability = TranscriberFactory.analyzerAvailable
        originalLegacyLocales = TranscriberFactory.legacySupportedLocales
        TranscriberFactory.analyzerAvailable = false
        TranscriberFactory.legacySupportedLocales = { ["en-US"] }
    }

    override func tearDown() async throws {
        TranscriberFactory.analyzerAvailable = originalAnalyzerAvailability
        TranscriberFactory.legacySupportedLocales = originalLegacyLocales
    }

    func testTheSessionTranscriberHearsTheTriggersOfEnabledCardsOnly() throws {
        let settings = makeTestSettings(for: self)
        settings.cards.add(Card(title: "Acme", triggers: ["Acme Cloud"], body: "One-liner"))
        settings.cards.add(Card(title: "Old", triggers: ["Retired Thing"], body: "Gone", isEnabled: false))

        let transcriber = try XCTUnwrap(TranscriberFactory.makeForSession(settings: settings) as? LegacySpeechTranscriber)

        XCTAssertTrue(transcriber.vocabulary.contains("Acme Cloud"))
        XCTAssertFalse(transcriber.vocabulary.contains("Retired Thing"))
    }

    func testTheUsersOwnTermsStillComeFirst() throws {
        let settings = makeTestSettings(for: self)
        settings.vocabularyText = "Slate"
        settings.cards.add(Card(title: "Acme", triggers: ["Acme Cloud"], body: "One-liner"))

        let transcriber = try XCTUnwrap(TranscriberFactory.makeForSession(settings: settings) as? LegacySpeechTranscriber)

        XCTAssertEqual(transcriber.vocabulary.first, "Slate")
    }
}
