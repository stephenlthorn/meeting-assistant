import XCTest

/// Listening to one app only: what the controller asks of system audio, and how
/// it shows what system audio reports back (M2).
@MainActor
final class CaptureTargetTests: XCTestCase {
    func testEveryAppIsHeardUnlessAnAppWasChosen() async {
        let h = LifecycleHarness(testCase: self)

        await h.startListening()

        XCTAssertEqual(h.systemAudio.applications, [nil])
    }

    func testTheChosenAppIsAskedForAtStart() async {
        let h = LifecycleHarness(testCase: self)
        h.settings.captureAppBundleID = "us.zoom.xos"

        await h.startListening()

        XCTAssertEqual(h.systemAudio.applications, ["us.zoom.xos"])
    }

    func testARestartAfterTheStreamDiesUsesTheChoiceAsItIsThen() async {
        let h = LifecycleHarness(testCase: self)
        h.settings.captureAppBundleID = "us.zoom.xos"
        await h.startListening()

        h.settings.captureAppBundleID = "com.google.Chrome"
        h.systemAudio.onError?("The display went to sleep")
        h.scheduler.fireAll()

        await eventually { h.systemAudio.applications.count == 2 }
        XCTAssertEqual(h.systemAudio.applications, ["us.zoom.xos", "com.google.Chrome"])
    }

    func testAWatchdogRestartAsksForTheChosenAppToo() async {
        let h = LifecycleHarness(testCase: self)
        h.settings.captureAppBundleID = "us.zoom.xos"
        await h.startListening()

        await h.pass(30, hearing: [.you])
        h.scheduler.fireAll()

        await eventually { h.systemAudio.applications == ["us.zoom.xos", "us.zoom.xos"] }
    }

    func testChangingTheAppMidCallLeavesTheRunningStreamAlone() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        h.settings.captureAppBundleID = "us.zoom.xos"
        await settle()

        XCTAssertEqual(h.systemAudio.events, ["start", "started"])
        XCTAssertEqual(h.controller.status, "Listening (on-device)")
    }

    // MARK: - Notices

    func testAFallbackToAllAppsIsShownAsANotice() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        h.systemAudio.notice("Zoom is not running, listening to all apps")

        XCTAssertEqual(h.controller.notice, "Zoom is not running, listening to all apps")
        XCTAssertEqual(h.controller.problems, [], "it is not a problem, capture works")
        XCTAssertEqual(h.controller.status, "Listening (on-device)")
    }

    func testTheNoticeClearsWhenCaptureReportsNothingToSay() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.notice("Zoom is not running, listening to all apps")

        h.systemAudio.notice(nil)

        XCTAssertNil(h.controller.notice)
    }

    func testSpeechNoticesAndTheCaptureNoticeDoNotWipeEachOther() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let them = h.transcribers.latest(.them)

        h.systemAudio.notice("Zoom is not running, listening to all apps")
        them?.notice("Downloading the on-device speech model…")
        XCTAssertEqual(h.controller.notice,
                       "Zoom is not running, listening to all apps\nDownloading the on-device speech model…")

        them?.notice(nil)
        XCTAssertEqual(h.controller.notice, "Zoom is not running, listening to all apps")

        them?.notice("Downloading the on-device speech model…")
        h.systemAudio.notice(nil)
        XCTAssertEqual(h.controller.notice, "Downloading the on-device speech model…")
    }

    func testTheCaptureNoticeDoesNotSurviveStopping() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.notice("Zoom is not running, listening to all apps")

        h.controller.stop()

        XCTAssertNil(h.controller.notice)
    }

    func testTheCaptureNoticeGoesWhenTheirSideFails() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.notice("Zoom is not running, listening to all apps")

        h.systemAudio.onError?(CaptureFailure(message: "The user stopped the stream", isRetryable: false))

        XCTAssertNil(h.controller.notice, "it no longer listens to anything")
    }

    func testTheCaptureNoticeStaysWhileTheirSideReconnects() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.notice("Zoom is not running, listening to all apps")

        h.systemAudio.onError?("The display went to sleep")

        XCTAssertEqual(h.controller.notice, "Zoom is not running, listening to all apps")
    }

    func testALateNoticeFromAnEarlierSessionIsIgnored() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let oldHandler = h.systemAudio.onNotice
        h.controller.stop()
        await h.startListening()

        oldHandler?("Zoom is not running, listening to all apps")

        XCTAssertNil(h.controller.notice)
    }
}
