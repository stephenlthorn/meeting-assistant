import XCTest

@MainActor
final class TranscriberFactoryTests: XCTestCase {
    private var originalAnalyzerAvailability = TranscriberFactory.analyzerAvailable

    override func setUp() async throws {
        originalAnalyzerAvailability = TranscriberFactory.analyzerAvailable
    }

    override func tearDown() async throws {
        TranscriberFactory.analyzerAvailable = originalAnalyzerAvailability
    }

    func testDeepgramIsOnlyUsedOnceSendingItAudioIsAccepted() {
        let settings = makeTestSettings(for: self, environment: ["DEEPGRAM_API_KEY": "dg-key"])
        settings.useCloudSTT = true

        XCTAssertEqual(TranscriberFactory.make(settings: settings).backendName, "on-device")

        settings.acceptCloudAudio()

        XCTAssertEqual(TranscriberFactory.make(settings: settings).backendName, "Deepgram")
    }

    func testDeepgramNeedsAKey() {
        let settings = makeTestSettings(for: self)
        settings.acceptCloudAudio()

        XCTAssertEqual(TranscriberFactory.make(settings: settings).backendName, "on-device")
    }

    // MARK: - The plan

    func testDeepgramIsPlannedOnlyWithTheSwitchTheAgreementAndAKey() {
        let settings = makeTestSettings(for: self, environment: ["DEEPGRAM_API_KEY": "dg-key"])
        XCTAssertNotEqual(TranscriberFactory.plan(for: settings, analyzerAvailable: true), .deepgram)

        settings.useCloudSTT = true
        XCTAssertNotEqual(TranscriberFactory.plan(for: settings, analyzerAvailable: true), .deepgram)

        settings.acceptCloudAudio()
        XCTAssertEqual(TranscriberFactory.plan(for: settings, analyzerAvailable: true), .deepgram)

        settings.useCloudSTT = false
        XCTAssertEqual(TranscriberFactory.plan(for: settings, analyzerAvailable: true), .analyzer)
    }

    func testTheNewerSpeechEngineStaysOnTheMacWhateverTheAppleServersConsent() {
        let settings = makeTestSettings(for: self)
        settings.acceptServerSpeech()

        XCTAssertEqual(TranscriberFactory.plan(for: settings, analyzerAvailable: true), .analyzer)
    }

    func testTheOlderSpeechEngineMayUseAppleServersOnlyAfterTheUserAllowsIt() {
        let settings = makeTestSettings(for: self)
        XCTAssertEqual(TranscriberFactory.plan(for: settings, analyzerAvailable: false),
                       .legacy(allowServerRecognition: false))

        settings.acceptServerSpeech()
        XCTAssertEqual(TranscriberFactory.plan(for: settings, analyzerAvailable: false),
                       .legacy(allowServerRecognition: true))

        settings.revokeServerSpeech()
        XCTAssertEqual(TranscriberFactory.plan(for: settings, analyzerAvailable: false),
                       .legacy(allowServerRecognition: false))
    }

    func testAnUnreadableDeepgramKeyFallsBackToOnDeviceSpeech() {
        let settings = makeTestSettings(for: self, secrets: LockedSecretStore(values: ["deepgram_api_key": "dg"]))
        settings.acceptCloudAudio()
        TranscriberFactory.analyzerAvailable = true

        let transcriber = TranscriberFactory.make(settings: settings)

        XCTAssertEqual(transcriber.backendName, "on-device")
        XCTAssertEqual(TranscriberFactory.plan(for: settings), .analyzer)
    }

    func testTheOlderSpeechEngineIsBuiltWhenTheNewerOneIsUnavailable() {
        let settings = makeTestSettings(for: self)
        TranscriberFactory.analyzerAvailable = false

        XCTAssertTrue(TranscriberFactory.make(settings: settings) is LegacySpeechTranscriber)
    }
}
