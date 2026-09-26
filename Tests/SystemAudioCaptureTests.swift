import ScreenCaptureKit
import XCTest

final class SystemAudioCaptureTests: XCTestCase {
    func testCaptureAsksForMonoSixteenKilohertzAudio() {
        let configuration = SystemAudioCapture.makeConfiguration()

        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertEqual(configuration.sampleRate, 16_000)
        XCTAssertEqual(configuration.channelCount, 1)
    }

    func testTheAppsOwnSoundsAreLeftOut() {
        XCTAssertTrue(SystemAudioCapture.makeConfiguration().excludesCurrentProcessAudio)
    }

    func testTheRequiredVideoStreamIsTinyAndRare() {
        let configuration = SystemAudioCapture.makeConfiguration()

        XCTAssertEqual(configuration.width, 2)
        XCTAssertEqual(configuration.height, 2)
        XCTAssertGreaterThanOrEqual(configuration.minimumFrameInterval.seconds, 1)
    }
}
