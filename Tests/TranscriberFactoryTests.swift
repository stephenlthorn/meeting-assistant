import XCTest

@MainActor
final class TranscriberFactoryTests: XCTestCase {
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
}
