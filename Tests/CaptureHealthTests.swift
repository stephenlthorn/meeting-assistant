import XCTest

/// What the controller does when a side of the call stops working without the
/// capture itself saying so: a transcriber that gives up, a stream that goes
/// quiet, a recognizer that hears speech and writes nothing.
@MainActor
final class CaptureHealthTests: XCTestCase {
    private let rejectedKey = "Deepgram rejected the API key (401). Check it in Settings."

    // MARK: - A transcriber that gives up (M1)

    func testTheirTranscriberGivingUpLeavesYourSideOnlyAndStopsTheirCapture() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        h.transcribers.latest(.them)?.die(rejectedKey)

        XCTAssertEqual(h.controller.status, "Listening (on-device, your side only)")
        XCTAssertEqual(h.controller.listening, .listening)
        XCTAssertEqual(h.controller.problems.map(\.message), ["Them: \(rejectedKey)"])
        await eventually { h.systemAudio.events.last == "stopped" }
        h.systemAudio.onBuffer?(silentBuffer())
        XCTAssertEqual(h.transcribers.latest(.them)?.appended, 0, "a dead transcriber takes no more audio")
        XCTAssertEqual(h.microphone.isRunning, true, "your side carries on")
    }

    func testYourTranscriberGivingUpLeavesTheirSideOnlyAndReleasesTheMicrophone() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        h.transcribers.latest(.you)?.die(rejectedKey)

        XCTAssertEqual(h.controller.status, "Listening (on-device, their side only)")
        XCTAssertEqual(h.controller.problems.map(\.message), ["You: \(rejectedKey)"])
        XCTAssertFalse(h.microphone.isRunning, "nothing is listening to the microphone for")
        h.microphone.onBuffer?(silentBuffer())
        XCTAssertEqual(h.transcribers.latest(.you)?.appended, 0)
        XCTAssertTrue(h.systemAudio.isCapturing, "their side carries on")
    }

    func testBothTranscribersGivingUpEndsTheSessionWithTheProblemsShown() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        h.transcribers.latest(.them)?.die(rejectedKey)
        h.transcribers.latest(.you)?.die(rejectedKey)

        XCTAssertEqual(h.controller.listening, .idle)
        XCTAssertEqual(h.controller.status, "Not listening")
        XCTAssertEqual(h.controller.problems.map(\.message), ["Them: \(rejectedKey)", "You: \(rejectedKey)"])
        await eventually { h.systemAudio.events.last == "stopped" }
        XCTAssertFalse(h.microphone.isRunning)
    }

    func testATranscriberGivingUpWhileTheirCaptureIsStillStartingIsNotUndoneByItsStart() async {
        let h = LifecycleHarness(testCase: self)
        h.systemAudio.holdsStart = true
        h.controller.start()
        await eventually { h.systemAudio.events == ["start"] && h.controller.listening == .listening }

        h.transcribers.latest(.them)?.die(rejectedKey)
        h.systemAudio.releaseStart()

        await eventually { h.systemAudio.events.last == "stopped" }
        XCTAssertEqual(h.controller.status, "Listening (on-device, your side only)")
        XCTAssertEqual(h.controller.problems.map(\.message), ["Them: \(rejectedKey)"])
    }

    func testAWakeDoesNotRevivePermanentlyDeadSpeechRecognition() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.transcribers.latest(.them)?.die(rejectedKey)
        await eventually { h.systemAudio.events.last == "stopped" }

        h.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle()

        XCTAssertEqual(h.systemAudio.events, ["start", "started", "stop", "stopped"])
        XCTAssertEqual(h.controller.status, "Listening (on-device, your side only)")
    }

    func testAGiveUpAfterStoppingOrFromAnEarlierSessionIsIgnored() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let old = h.transcribers.latest(.them)
        h.controller.stop()
        old?.onFatal?(rejectedKey)
        XCTAssertEqual(h.controller.status, "Stopped")

        await h.startListening()
        old?.onFatal?(rejectedKey)

        XCTAssertEqual(h.controller.status, "Listening (on-device)")
        XCTAssertEqual(h.controller.problems, [])
    }

    func testAGiveUpFromATranscriberThatWasReplacedIsIgnored() async {
        let h = LifecycleHarness(testCase: self)
        h.settings.setDeepgramKey("dg-key")
        h.settings.acceptCloudAudio()
        await h.startListening()
        let replaced = h.transcribers.latest(.them)
        h.settings.useCloudSTT = false
        await eventually { h.transcribers.made.count == 4 }

        replaced?.onFatal?(rejectedKey)

        XCTAssertEqual(h.controller.status, "Listening (on-device)")
        XCTAssertEqual(h.controller.problems, [])
    }

    func testTheReplacementOfADeadTranscriberIsLeftAlone() async {
        let h = LifecycleHarness(testCase: self)
        h.settings.setDeepgramKey("dg-key")
        h.settings.acceptCloudAudio()
        await h.startListening()
        h.transcribers.latest(.them)?.die(rejectedKey)
        await eventually { h.systemAudio.events.last == "stopped" }

        h.settings.useCloudSTT = false
        await settle()

        XCTAssertEqual(h.transcribers.made.count, 3, "only your side, which still runs, is replaced")
        XCTAssertEqual(h.controller.status, "Listening (on-device, your side only)")
    }

    // MARK: - Levels (M1)

    func testEachSidesLevelFollowsItsOwnAudio() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        XCTAssertEqual(h.controller.levels.them, 0)
        XCTAssertEqual(h.controller.levels.you, 0)

        h.systemAudio.onBuffer?(tone(amplitude: 0.1))
        await eventually { h.controller.levels.them > 0 }
        XCTAssertEqual(h.controller.levels.you, 0)

        h.microphone.onBuffer?(tone(amplitude: 0.1))
        await eventually { h.controller.levels.you > 0 }
    }

    func testLevelsAreNotPushedToTheMainActorBufferByBuffer() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onBuffer?(tone(amplitude: 0.1))
        await eventually { h.controller.levels.them > 0 }
        let first = h.controller.levels.them

        for _ in 0..<5 { h.systemAudio.onBuffer?(tone(amplitude: 0.9)) }
        await settle()
        XCTAssertEqual(h.controller.levels.them, first, "the next report is a tenth of a second away")

        h.meterClock.advance(0.11)
        h.systemAudio.onBuffer?(tone(amplitude: 0.9))
        await eventually { h.controller.levels.them > first }
    }

    func testStoppingZeroesTheLevelsAndLateAudioDoesNotRaiseThem() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onBuffer?(tone(amplitude: 0.1))
        await eventually { h.controller.levels.them > 0 }

        h.controller.stop()
        h.meterClock.advance(1)
        h.systemAudio.onBuffer?(tone(amplitude: 0.1))
        await settle()

        XCTAssertEqual(h.controller.levels.them, 0)
    }

    func testASideThatIsReconnectingShowsNoLevel() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onBuffer?(tone(amplitude: 0.1))
        await eventually { h.controller.levels.them > 0 }

        h.systemAudio.onError?("The display went to sleep")

        XCTAssertEqual(h.controller.levels.them, 0)
    }

    func testAMicrophoneThatFailedShowsNoLevel() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.microphone.onBuffer?(tone(amplitude: 0.1))
        await eventually { h.controller.levels.you > 0 }

        h.microphone.onError?("Device busy")

        XCTAssertEqual(h.controller.levels.you, 0)
    }
}
