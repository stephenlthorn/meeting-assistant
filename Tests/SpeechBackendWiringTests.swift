import AVFoundation
import Speech
import XCTest

@MainActor
final class SpeechBackendWiringTests: XCTestCase {
    private var originalAnalyzerAvailability = TranscriberFactory.analyzerAvailable
    private var originalLegacyLocales = TranscriberFactory.legacySupportedLocales

    override func setUp() async throws {
        originalAnalyzerAvailability = TranscriberFactory.analyzerAvailable
        originalLegacyLocales = TranscriberFactory.legacySupportedLocales
    }

    override func tearDown() async throws {
        TranscriberFactory.analyzerAvailable = originalAnalyzerAvailability
        TranscriberFactory.legacySupportedLocales = originalLegacyLocales
    }

    // MARK: - The factory hands the choices to each backend

    func testDeepgramReceivesTheLocaleAndTheVocabulary() throws {
        let settings = makeTestSettings(for: self, environment: ["DEEPGRAM_API_KEY": "dg-key"])
        settings.acceptCloudAudio()
        settings.speechLocaleIdentifier = "de-DE"
        settings.vocabularyText = "TiDB\nSlate"

        let transcriber = try XCTUnwrap(TranscriberFactory.make(settings: settings) as? CloudTranscriber)

        XCTAssertEqual(transcriber.localeIdentifier, "de-DE")
        XCTAssertEqual(transcriber.vocabulary, ["TiDB", "Slate"])
    }

    func testTheLegacyRecognizerReceivesTheLocaleAndTheVocabulary() throws {
        TranscriberFactory.analyzerAvailable = false
        TranscriberFactory.legacySupportedLocales = { ["en-US", "fr-FR"] }
        let settings = makeTestSettings(for: self)
        settings.speechLocaleIdentifier = "fr-FR"
        settings.vocabularyText = "Bellows"

        let transcriber = try XCTUnwrap(TranscriberFactory.make(settings: settings) as? LegacySpeechTranscriber)

        XCTAssertEqual(transcriber.localeIdentifier, "fr-FR")
        XCTAssertEqual(transcriber.vocabulary, ["Bellows"])
        XCTAssertNil(transcriber.languageNotice)
    }

    func testTheAnalyzerReceivesTheLocaleAndTheVocabulary() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        TranscriberFactory.analyzerAvailable = true
        let settings = makeTestSettings(for: self)
        settings.speechLocaleIdentifier = "es-ES"
        settings.vocabularyText = "Slate"

        let transcriber = try XCTUnwrap(TranscriberFactory.make(settings: settings) as? AnalyzerTranscriber)

        XCTAssertEqual(transcriber.requestedLocaleIdentifier, "es-ES")
        XCTAssertEqual(transcriber.vocabulary, ["Slate"])
    }

    func testExtraTermsJoinTheUserTermsAndUserTermsWinTheCap() throws {
        TranscriberFactory.analyzerAvailable = false
        TranscriberFactory.legacySupportedLocales = { ["en-US"] }
        let settings = makeTestSettings(for: self)
        settings.vocabularyText = (1...100).map { "user\($0)" }.joined(separator: "\n")

        let transcriber = try XCTUnwrap(
            TranscriberFactory.make(settings: settings, extraVocabulary: ["trigger"]) as? LegacySpeechTranscriber)

        XCTAssertEqual(transcriber.vocabulary.count, 100)
        XCTAssertFalse(transcriber.vocabulary.contains("trigger"))
    }

    func testTheSessionsFrozenOptionsBeatLaterSettingsChanges() throws {
        TranscriberFactory.analyzerAvailable = false
        TranscriberFactory.legacySupportedLocales = { ["en-US", "fr-FR", "de-DE"] }
        let settings = makeTestSettings(for: self)
        settings.speechLocaleIdentifier = "fr-FR"
        settings.freezeSpeechOptions()
        settings.speechLocaleIdentifier = "de-DE"

        let transcriber = try XCTUnwrap(TranscriberFactory.make(settings: settings) as? LegacySpeechTranscriber)

        XCTAssertEqual(transcriber.localeIdentifier, "fr-FR")
    }

    func testAnUnsupportedSavedLocaleOnTheLegacyPathFallsBackWithANotice() async throws {
        TranscriberFactory.analyzerAvailable = false
        TranscriberFactory.legacySupportedLocales = { ["en-US"] }
        let settings = makeTestSettings(for: self)
        settings.speechLocaleIdentifier = "th-TH"

        let transcriber = try XCTUnwrap(TranscriberFactory.make(settings: settings) as? LegacySpeechTranscriber)

        XCTAssertEqual(transcriber.localeIdentifier, "en-US")
        XCTAssertTrue(try XCTUnwrap(transcriber.languageNotice).contains("Thai"))
    }

    func testTheLegacyTranscriberShowsItsLanguageNoticeWhenItStarts() async {
        let engine = LanguageFakeEngine()
        let transcriber = LegacySpeechTranscriber(engine: engine, localeIdentifier: "en-US", vocabulary: [],
                                                  languageNotice: "Thai isn't available here, so English is used.")
        var notices: [String?] = []
        transcriber.onNotice = { notices.append($0) }

        transcriber.start()
        await eventually { notices.contains("Thai isn't available here, so English is used.") }
    }

    // MARK: - SFSpeechRecognizer request

    func testTheLegacyRecognitionRequestCarriesTheVocabulary() {
        let request = AppleSpeechEngine.makeRequest(onDevice: true, vocabulary: ["TiDB", "Bellows"])

        XCTAssertEqual(request.contextualStrings, ["TiDB", "Bellows"])
    }

    func testTheLegacyRecognitionRequestWithoutVocabularyHasNoContextualStrings() {
        XCTAssertTrue(AppleSpeechEngine.makeRequest(onDevice: false, vocabulary: []).contextualStrings.isEmpty)
    }

    // MARK: - SpeechAnalyzer context

    func testTheAnalyzerContextCarriesTheVocabularyUnderTheGeneralTag() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }

        let context = try XCTUnwrap(SpeechAnalyzerPipeline.analysisContext(vocabulary: ["TiDB", "Slate"]))

        XCTAssertEqual(context.contextualStrings[.general], ["TiDB", "Slate"])
    }

    func testNoVocabularyMeansNoAnalyzerContext() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }

        XCTAssertNil(SpeechAnalyzerPipeline.analysisContext(vocabulary: []))
    }

    // MARK: - A model that cannot be downloaded is never silent

    func testAFailedModelDownloadIsReportedAtOnceNotAfterThreeTries() async {
        let gate = PipelineGate()
        gate.error = AnalyzerSetupError.modelDownloadFailed(language: "Spanish", reason: "The Internet connection appears to be offline.")
        let transcriber = AnalyzerTranscriber(makePipeline: gate.make, schedule: { _, _ in })
        var errors: [String] = []
        transcriber.onError = { errors.append($0) }

        transcriber.start()

        await eventually { !errors.isEmpty }
        XCTAssertTrue(errors[0].contains("Spanish"), errors[0])
        XCTAssertTrue(errors[0].contains("offline"), errors[0])
    }

    // MARK: - Deepgram URL

    func testTheDeepgramURLCarriesTheLanguageOnlyWhenItIsMapped() throws {
        let mapped = CloudTranscriber.listenURL(localeIdentifier: "de-DE", vocabulary: []).url
        let unmapped = CloudTranscriber.listenURL(localeIdentifier: "xx-YY", vocabulary: []).url

        XCTAssertEqual(queryValues(of: mapped, "language"), ["de"])
        XCTAssertEqual(queryValues(of: unmapped, "language"), [])
        XCTAssertEqual(queryValues(of: unmapped, "model"), ["nova-3"])
    }

    func testTheDeepgramURLHasOneKeytermPerPhraseEncoded() throws {
        let url = CloudTranscriber.listenURL(localeIdentifier: "en-US",
                                             vocabulary: ["TiDB", "Pied Piper", "C++ & Rust"]).url

        XCTAssertEqual(queryValues(of: url, "keyterm"), ["TiDB", "Pied Piper", "C++ & Rust"])
        XCTAssertTrue(url.absoluteString.contains("keyterm=Pied%20Piper"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("keyterm=C%2B%2B%20%26%20Rust"), url.absoluteString)
    }

    func testTheDeepgramURLStaysUnderTheLengthLimitAndReportsWhatItDropped() {
        let phrases = (1...100).map { "a fairly long phrase number \($0) here" }

        let built = CloudTranscriber.listenURL(localeIdentifier: "en-US", vocabulary: phrases)

        XCTAssertLessThanOrEqual(built.url.absoluteString.count, CloudTranscriber.maximumURLLength)
        XCTAssertGreaterThan(built.droppedKeyterms, 0)
        XCTAssertEqual(queryValues(of: built.url, "keyterm").count + built.droppedKeyterms, 100)
        XCTAssertEqual(queryValues(of: built.url, "keyterm").first, phrases.first,
                       "the phrases that fit are the earliest ones")
    }

    func testAShortListDropsNothing() {
        XCTAssertEqual(CloudTranscriber.listenURL(localeIdentifier: "en-US", vocabulary: ["TiDB"]).droppedKeyterms, 0)
    }

    func testTheConnectionRequestUsesTheLanguageAndKeyterms() async throws {
        let sockets = FakeSocketServer()
        let queue = DispatchQueue(label: "SpeechBackendWiringTests")
        let transcriber = CloudTranscriber(apiKey: "dg-key", localeIdentifier: "fr-FR", vocabulary: ["Bellows"],
                                           connect: sockets.connect, queue: queue, schedule: { _, _ in })

        transcriber.start()
        queue.sync {}

        let url = try XCTUnwrap(sockets.requests.first?.url)
        XCTAssertEqual(queryValues(of: url, "language"), ["fr"])
        XCTAssertEqual(queryValues(of: url, "keyterm"), ["Bellows"])
    }

    func testAnUnmappedLanguageIsSaidOutLoudNotLeftToDefaultToEnglishSilently() async {
        let sockets = FakeSocketServer()
        let queue = DispatchQueue(label: "SpeechBackendWiringTests.unmapped")
        let transcriber = CloudTranscriber(apiKey: "dg-key", localeIdentifier: "xx-YY",
                                           connect: sockets.connect, queue: queue, schedule: { _, _ in })
        var notices: [String?] = []
        transcriber.onNotice = { notices.append($0) }

        transcriber.start()
        queue.sync {}

        await eventually { notices.compactMap { $0 }.contains { $0.contains("English") } }
    }

    // MARK: - Helpers

    private func queryValues(of url: URL, _ name: String) -> [String] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == name }.compactMap(\.value) ?? []
    }
}

private final class LanguageFakeEngine: SpeechRecognitionEngine {
    var isAvailable: Bool { true }
    var supportsOnDeviceRecognition: Bool { true }
    func requestAuthorization(_ completion: @escaping (Bool) -> Void) { completion(true) }
    func startSession(onResult: @escaping (String, Bool) -> Void,
                      onError: @escaping (Error) -> Void) -> SpeechRecognitionSession {
        LanguageFakeSession()
    }
}

private final class LanguageFakeSession: SpeechRecognitionSession {
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() {}
    func cancel() {}
}
