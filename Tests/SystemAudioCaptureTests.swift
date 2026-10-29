import ScreenCaptureKit
import XCTest

@MainActor
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

    // MARK: - Which app (M2)

    private let zoom = CaptureApplication(bundleID: "us.zoom.xos", name: "zoom.us")

    func testWithoutAChosenAppEveryAppIsCaptured() async throws {
        let h = CaptureHarness()
        h.backend.applications = [zoom]

        try await h.capture.start(application: nil)

        XCTAssertNil(h.backend.latest?.application)
        await eventually { h.reports.notices == [nil] }
    }

    func testTheChosenAppIsCapturedOnItsOwnWhenItIsRunning() async throws {
        let h = CaptureHarness()
        h.backend.applications = [CaptureApplication(bundleID: "com.apple.Safari", name: "Safari"), zoom]

        try await h.capture.start(application: "us.zoom.xos")

        XCTAssertEqual(h.backend.latest?.application, zoom)
        XCTAssertEqual(h.backend.streams.count, 1)
        await eventually { h.reports.notices == [nil] }
    }

    func testAChosenAppThatIsNotRunningFallsBackToAllAppsAndSaysSo() async throws {
        let h = CaptureHarness()
        h.backend.applications = [CaptureApplication(bundleID: "com.apple.Safari", name: "Safari")]

        try await h.capture.start(application: "us.zoom.xos")

        XCTAssertNil(h.backend.latest?.application)
        XCTAssertEqual(h.backend.streams.count, 1, "it still listens")
        await eventually { h.reports.notices == ["Zoom is not running, listening to all apps"] }
    }

    func testAnAppNotOnTheListIsNamedByItsIdentifierInTheNotice() async throws {
        let h = CaptureHarness()

        try await h.capture.start(application: "com.example.callapp")

        await eventually { h.reports.notices == ["com.example.callapp is not running, listening to all apps"] }
    }

    func testTheNoticeGoesAwayWhenALaterStartFindsTheApp() async throws {
        let h = CaptureHarness()
        try await h.capture.start(application: "us.zoom.xos")
        await eventually { h.reports.notices.count == 1 }

        h.backend.applications = [zoom]
        try await h.capture.start(application: "us.zoom.xos")

        await eventually { h.reports.notices == ["Zoom is not running, listening to all apps", nil] }
        XCTAssertEqual(h.backend.latest?.application, zoom)
    }

    func testTheMainDisplayIsStillPreferredWhenListeningToOneApp() async throws {
        let h = CaptureHarness()
        h.backend.displays = [CaptureDisplay(id: 5), CaptureDisplay(id: 7)]
        h.backend.mainDisplayID = 7
        h.backend.applications = [zoom]

        try await h.capture.start(application: "us.zoom.xos")

        XCTAssertEqual(h.backend.latest?.display, CaptureDisplay(id: 7))
    }

    func testNoDisplayIsAnErrorAndNothingStarts() async {
        let h = CaptureHarness()
        h.backend.displays = []

        do {
            try await h.capture.start(application: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SystemAudioError, .noDisplay)
        }
        XCTAssertTrue(h.backend.streams.isEmpty)
    }

    func testAFailureWithoutScreenRecordingPermissionAsksForItAndSaysSo() async {
        let h = CaptureHarness()
        h.backend.candidatesError = TestFailure(message: "The user declined TCC")
        h.backend.hasScreenRecordingPermission = false

        do {
            try await h.capture.start(application: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SystemAudioError, .permissionDenied)
        }
        XCTAssertEqual(h.backend.permissionRequests, 1)
    }

    func testAFailureWithPermissionIsPassedOnAsItIs() async {
        let h = CaptureHarness()
        h.backend.candidatesError = TestFailure(message: "Something else broke")

        do {
            try await h.capture.start(application: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Something else broke")
        }
        XCTAssertEqual(h.backend.permissionRequests, 0)
    }

    // MARK: - Streams

    func testStartingAgainStopsTheOldStreamFirst() async throws {
        let h = CaptureHarness()
        try await h.capture.start(application: nil)

        try await h.capture.start(application: nil)

        XCTAssertEqual(h.backend.streams.map(\.stops), [1, 0])
        XCTAssertEqual(h.backend.streams.map(\.starts), [1, 1])
    }

    func testOnlyTheCurrentStreamsAudioIsDelivered() async throws {
        let h = CaptureHarness()
        try await h.capture.start(application: nil)
        let old = try XCTUnwrap(h.backend.latest)
        try await h.capture.start(application: nil)

        old.hear()
        XCTAssertEqual(h.reports.buffersHeard, 0)

        h.backend.latest?.hear()
        XCTAssertEqual(h.reports.buffersHeard, 1)
    }

    func testAStreamThatStopsByItselfIsReportedWithWhetherRetryingCanHelp() async throws {
        let h = CaptureHarness()
        try await h.capture.start(application: nil)

        h.backend.latest?.die(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue,
                                      userInfo: [NSLocalizedDescriptionKey: "The user stopped the stream"]))

        await eventually { h.reports.failures.count == 1 }
        XCTAssertEqual(h.reports.failures, [CaptureFailure(message: "The user stopped the stream", isRetryable: false)])
    }

    func testOnlyTheCurrentStreamsDeathIsReported() async throws {
        let h = CaptureHarness()
        try await h.capture.start(application: nil)
        let old = try XCTUnwrap(h.backend.latest)
        try await h.capture.start(application: nil)

        old.die(TestFailure(message: "The old stream finally noticed"))
        await settle()

        XCTAssertEqual(h.reports.failures, [])
    }

    func testAStreamThatStoppedByItselfCannotStopTheNextOneByReportingAgain() async throws {
        let h = CaptureHarness()
        try await h.capture.start(application: nil)
        let first = try XCTUnwrap(h.backend.latest)
        first.die(TestFailure(message: "Display went to sleep"))
        try await h.capture.start(application: nil)

        first.die(TestFailure(message: "again"))
        await settle()

        XCTAssertEqual(h.reports.failures.map(\.message), ["Display went to sleep"])
    }

    func testStoppingDropsLaterAudio() async throws {
        let h = CaptureHarness()
        try await h.capture.start(application: nil)
        let stream = try XCTUnwrap(h.backend.latest)

        await h.capture.stop()
        stream.hear()

        XCTAssertEqual(h.reports.buffersHeard, 0)
        XCTAssertEqual(stream.stops, 1)
    }

    func testAStreamThatFailsToStartLeavesNothingBehind() async throws {
        let h = CaptureHarness()
        h.backend.streamStartError = TestFailure(message: "Could not start")

        do {
            try await h.capture.start(application: nil)
            XCTFail("expected an error")
        } catch {}
        let stream = try XCTUnwrap(h.backend.latest)
        stream.hear()

        XCTAssertEqual(h.reports.buffersHeard, 0)
        await h.capture.stop()
        XCTAssertEqual(stream.stops, 0, "nothing was running, so there is nothing to stop")
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

/// A capture over a fake ScreenCaptureKit, with its reports collected.
@MainActor
private struct CaptureHarness {
    let backend = FakeScreenCaptureBackend()
    let capture: SystemAudioCapture
    let reports: CaptureReports

    init() {
        capture = SystemAudioCapture(backend: backend)
        reports = CaptureReports(capture)
    }
}
