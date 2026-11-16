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

    // MARK: - Triggers stay on the Mac

    func testDeepgramNeverHearsCardTriggers() throws {
        let settings = makeTestSettings(for: self, environment: ["DEEPGRAM_API_KEY": "dg-key"])
        settings.useCloudSTT = true
        settings.acceptCloudAudio()
        settings.vocabularyText = "Slate"
        settings.cards.add(Card(title: "Acme", triggers: ["Acme Cloud"], body: "One-liner"))

        let transcriber = try XCTUnwrap(TranscriberFactory.makeForSession(settings: settings) as? CloudTranscriber)

        XCTAssertEqual(transcriber.vocabulary, ["Slate"])
    }

    func testAppleServerModeNeverHearsCardTriggers() throws {
        let settings = makeTestSettings(for: self)
        settings.acceptServerSpeech()
        settings.cards.add(Card(title: "Acme", triggers: ["Acme Cloud"], body: "One-liner"))

        let transcriber = try XCTUnwrap(TranscriberFactory.makeForSession(settings: settings) as? LegacySpeechTranscriber)

        XCTAssertFalse(transcriber.vocabulary.contains("Acme Cloud"))
    }

    func testTheNewerOnDeviceEngineHearsCardTriggers() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        TranscriberFactory.analyzerAvailable = true
        let settings = makeTestSettings(for: self)
        settings.acceptServerSpeech()
        settings.cards.add(Card(title: "Acme", triggers: ["Acme Cloud"], body: "One-liner"))

        let transcriber = try XCTUnwrap(TranscriberFactory.makeForSession(settings: settings) as? AnalyzerTranscriber)

        XCTAssertTrue(transcriber.vocabulary.contains("Acme Cloud"))
    }

    func testCardEditsAfterStartNeverReachARestartedTranscriber() throws {
        let settings = makeTestSettings(for: self)
        settings.cards.add(Card(title: "Acme", triggers: ["Acme Cloud"], body: "One-liner"))
        settings.freezeSpeechOptions()

        settings.cards.add(Card(title: "Beta", triggers: ["Beta Cloud"], body: "One-liner"))
        let restarted = try XCTUnwrap(TranscriberFactory.makeForSession(settings: settings) as? LegacySpeechTranscriber)

        XCTAssertTrue(restarted.vocabulary.contains("Acme Cloud"))
        XCTAssertFalse(restarted.vocabulary.contains("Beta Cloud"))
    }

    func testStoppingForgetsTheSnapshotSoTheNextSessionSeesNewCards() throws {
        let settings = makeTestSettings(for: self)
        settings.freezeSpeechOptions()
        settings.releaseSpeechOptions()
        settings.cards.add(Card(title: "Beta", triggers: ["Beta Cloud"], body: "One-liner"))

        let next = try XCTUnwrap(TranscriberFactory.makeForSession(settings: settings) as? LegacySpeechTranscriber)

        XCTAssertTrue(next.vocabulary.contains("Beta Cloud"))
    }
}
