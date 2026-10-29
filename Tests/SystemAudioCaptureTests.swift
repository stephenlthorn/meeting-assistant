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

    // MARK: - Which display

    func testTheMainDisplayIsPreferred() {
        let displays = [FakeDisplay(displayID: 5), FakeDisplay(displayID: 7), FakeDisplay(displayID: 9)]

        let chosen = SystemAudioCapture.preferredDisplay(displays, mainDisplayID: 7, id: \.displayID)

        XCTAssertEqual(chosen, FakeDisplay(displayID: 7))
    }

    func testWithoutTheMainDisplayTheFirstOneIsUsed() {
        let displays = [FakeDisplay(displayID: 5), FakeDisplay(displayID: 9)]

        XCTAssertEqual(SystemAudioCapture.preferredDisplay(displays, mainDisplayID: 7, id: \.displayID),
                       FakeDisplay(displayID: 5))
        XCTAssertNil(SystemAudioCapture.preferredDisplay([FakeDisplay](), mainDisplayID: 7, id: \.displayID))
    }

    // MARK: - Which stops are worth restarting

    func testStoppingSharingOrDecliningPermissionIsNotRetried() {
        for code in [SCStreamError.Code.userStopped, .userDeclined, .missingEntitlements] {
            let error = NSError(domain: SCStreamErrorDomain, code: code.rawValue)
            XCTAssertFalse(SystemAudioCapture.isRetryable(error), "\(code)")
        }
    }

    func testOtherStopsAreWorthRetrying() {
        let interrupted = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedApplicationConnectionInterrupted.rawValue)
        let unknown = NSError(domain: "SomethingElse", code: SCStreamError.Code.userStopped.rawValue)

        XCTAssertTrue(SystemAudioCapture.isRetryable(interrupted))
        XCTAssertTrue(SystemAudioCapture.isRetryable(unknown))
        XCTAssertTrue(SystemAudioCapture.isRetryable(TestFailure(message: "The display went to sleep")))
    }
}

private struct FakeDisplay: Equatable {
    let displayID: CGDirectDisplayID
}
