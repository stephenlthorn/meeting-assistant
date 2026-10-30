import XCTest

/// What happens to each side's transcriber when a privacy setting changes in the
/// middle of a call (round 2: CAP2-1, CAP2-2, CAP2-8 and codex P1 #1). The old
/// backend is cut off for good, and no side can ever bring it back.
@MainActor
final class PrivacyRestartTests: XCTestCase {
    // MARK: - The old transcribers are cancelled, not drained

    func testWithdrawingConsentCancelsTheOldTranscribersAndAUserStopStillDrains() async {
        let h = await deepgramHarness()
        let cloudThem = h.transcribers.latest(.them)
        let cloudYou = h.transcribers.latest(.you)

        h.settings.useCloudSTT = false
        await eventually { h.transcribers.made.count == 4 }

        XCTAssertEqual(cloudThem?.cancels, 1, "audio still queued for Deepgram must not be sent")
        XCTAssertEqual(cloudYou?.cancels, 1)
        h.controller.stop()
        XCTAssertEqual(h.transcribers.latest(.them)?.cancels, 0, "a user's Stop lets the last words arrive")
        XCTAssertEqual(h.transcribers.latest(.them)?.stops, 1)
    }

    func testAStopRightAfterWithdrawingConsentCancelsInsteadOfDraining() async {
        let h = await deepgramHarness()
        let cloudThem = h.transcribers.latest(.them)
        let cloudYou = h.transcribers.latest(.you)

        h.settings.useCloudSTT = false
        h.controller.stop()

        XCTAssertEqual(cloudThem?.cancels, 1, "the withdrawal had not been applied yet, and Stop must not drain Deepgram")
        XCTAssertEqual(cloudYou?.cancels, 1)
    }

    func testAStopAfterTurningDeepgramOnStillDrains() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        h.settings.setDeepgramKey("dg-key")
        h.settings.acceptCloudAudio()
        h.controller.stop()

        XCTAssertEqual(h.transcribers.latest(.them)?.cancels, 0, "turning something on is not a withdrawal")
        XCTAssertEqual(h.transcribers.latest(.them)?.stops, 1)
    }

    // MARK: - A side that was down cannot bring the old backend back (CAP2-1)

    func testAMicrophoneThatReturnsAfterDeepgramWasSwitchedOffRestartsOnDeviceSpeechNotDeepgram() async {
        let h = await deepgramHarness()
        let cloudYou = h.transcribers.latest(.you)
        h.microphone.onError?("Couldn't restart the microphone")

        h.settings.useCloudSTT = false
        await eventually { h.transcribers.made.count == 4 }
        h.microphone.onRecovered?()
        h.microphone.onBuffer?(silentBuffer())

        XCTAssertEqual(cloudYou?.starts, 1, "only the start it had before the switch")
        XCTAssertEqual(cloudYou?.appended, 0, "no microphone audio goes to Deepgram")
        XCTAssertEqual(cloudYou?.cancels, 1)
        let fresh = h.transcribers.latest(.you)
        XCTAssertEqual(fresh?.starts, 1)
        XCTAssertEqual(fresh?.appended, 1)
        XCTAssertEqual(h.controller.status, "Listening (on-device)")
    }

    func testTheirSideRevivedAfterDeepgramWasSwitchedOffRestartsOnDeviceSpeechNotDeepgram() async {
        let h = await deepgramHarness()
        let cloudThem = h.transcribers.latest(.them)
        await giveUpOnSystemAudio(h)

        h.settings.useCloudSTT = false
        await eventually { h.transcribers.made.count == 4 }
        h.systemAudio.startError = nil
        h.workspaceNotifications.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await eventually { h.controller.status == "Listening (on-device)" }
        h.systemAudio.onBuffer?(silentBuffer())

        XCTAssertEqual(cloudThem?.starts, 1, "only the start it had before the switch")
        XCTAssertEqual(cloudThem?.appended, 0, "no meeting audio goes to Deepgram")
        let fresh = h.transcribers.latest(.them)
        XCTAssertEqual(fresh?.starts, 1)
        XCTAssertEqual(fresh?.appended, 1)
    }

    func testASideThatWasDownDuringTheSwitchIsReplacedWithoutBeingStarted() async {
        let h = await deepgramHarness()
        h.microphone.onError?("Couldn't restart the microphone")

        h.settings.useCloudSTT = false
        await eventually { h.transcribers.made.count == 4 }

        XCTAssertEqual(h.transcribers.latest(.you)?.starts, 0, "it starts only if its microphone comes back")
        XCTAssertEqual(h.controller.status, "Listening (on-device, their side only)")
    }

    // MARK: - A side that is reconnecting gets its replacement started (CAP2-2)

    func testASideReconnectingDuringTheSwitchHasItsReplacementStartedAndFed() async {
        let h = await deepgramHarness()
        h.systemAudio.onError?("The display went to sleep")

        h.settings.useCloudSTT = false
        await eventually { h.transcribers.made.count == 4 }
        await settle()
        h.scheduler.fireAll()
        await eventually { h.controller.status == "Listening (on-device)" }
        let fresh = h.transcribers.latest(.them)
        h.systemAudio.onBuffer?(silentBuffer())

        XCTAssertEqual(fresh?.starts, 1)
        XCTAssertEqual(fresh?.appended, 1)
    }

    func testAReplacementWaitingForPermissionIsStartedOnceEvenIfItsSideCameBackMeanwhile() async {
        let h = await deepgramHarness()
        h.transcribers.holdsAuthorization = true
        h.settings.useCloudSTT = false
        await eventually { h.transcribers.made.count == 4 }
        let fresh = h.transcribers.latest(.you)

        h.microphone.onError?("Device busy")
        h.microphone.onRecovered?()
        XCTAssertEqual(fresh?.starts, 0, "its permission question is still open")
        h.transcribers.latest(.them)?.resolveAuthorization()
        await eventually { fresh?.starts == 1 }
        await settle()

        XCTAssertEqual(fresh?.starts, 1, "started when the answer came, not also when the microphone returned")
    }

    // MARK: - Notices (CAP2-8)

    func testASwitchClearsTheNoticesOfTheTranscribersItReplaces() async {
        let h = await deepgramHarness()
        h.transcribers.latest(.them)?.notice("Reconnecting to Deepgram…")
        XCTAssertEqual(h.controller.notice, "Reconnecting to Deepgram…")

        h.settings.useCloudSTT = false
        await eventually { h.transcribers.made.count == 4 }

        XCTAssertNil(h.controller.notice)
    }

    func testALateNoticeOrErrorFromAReplacedTranscriberIsIgnored() async {
        let h = await deepgramHarness()
        let cloudThem = h.transcribers.latest(.them)
        h.settings.useCloudSTT = false
        await eventually { h.transcribers.made.count == 4 }
        h.transcribers.latest(.them)?.notice("On-device speech isn't available, so audio goes to Apple's servers.")

        cloudThem?.notice(nil)
        cloudThem?.notice("Reconnecting to Deepgram…")
        cloudThem?.fail("Deepgram keeps disconnecting")

        XCTAssertEqual(h.controller.notice, "On-device speech isn't available, so audio goes to Apple's servers.")
        XCTAssertEqual(h.controller.problems, [])
    }

    // MARK: - Harness

    private func deepgramHarness() async -> LifecycleHarness {
        let h = LifecycleHarness(testCase: self)
        h.settings.setDeepgramKey("dg-key")
        h.settings.acceptCloudAudio()
        h.transcribers.backendName = "Deepgram"
        await h.startListening()
        h.transcribers.backendName = "on-device"
        return h
    }

    /// Their capture dies and every restart fails until the controller gives up
    /// on it (a wake or a display change may still revive it).
    private func giveUpOnSystemAudio(_ h: LifecycleHarness) async {
        h.systemAudio.onError?("The display went to sleep")
        h.systemAudio.startError = TestFailure(message: "No display available for capture.")
        for _ in AssistantController.systemAudioRetryDelays {
            let failures = h.systemAudio.events.filter { $0 == "failed" }.count
            h.scheduler.fireAll()
            await eventually { h.systemAudio.events.filter { $0 == "failed" }.count == failures + 1 }
            await settle()
        }
        XCTAssertTrue(h.controller.status.hasSuffix("your side only)"), h.controller.status)
    }
}
