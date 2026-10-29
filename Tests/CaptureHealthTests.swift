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

    // MARK: - Capture that goes silent (M1)

    func testTheirSideGoingSilentForThirtySecondsIsRestartedThroughTheBackoffChain() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let them = h.transcribers.latest(.them)

        await h.pass(25, hearing: [.you])
        XCTAssertEqual(h.controller.status, "Listening (on-device)")
        await h.pass(5, hearing: [.you])

        XCTAssertEqual(h.controller.status, "Listening (on-device, reconnecting their side)")
        XCTAssertEqual(h.scheduler.delays, [1], "the first step of the same backoff as a stream that reports its death")
        h.scheduler.fireAll()
        await eventually { h.systemAudio.events == ["start", "started", "stop", "stopped", "start", "started"] }
        await eventually { h.controller.status == "Listening (on-device)" }
        XCTAssertTrue(h.transcribers.latest(.them) === them, "its transcriber carries on")
        XCTAssertEqual(h.controller.problems, [])
    }

    func testYourMicrophoneGoingSilentForThirtySecondsIsReconnected() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        await h.pass(25, hearing: [.them])
        XCTAssertEqual(h.microphone.reconnects, 0)
        await h.pass(5, hearing: [.them])

        XCTAssertEqual(h.microphone.reconnects, 1)
        XCTAssertEqual(h.controller.status, "Listening (on-device)", "the microphone retries by itself and reports only if that fails")
    }

    func testAStreamThatStaysSilentAfterItsRestartIsReportedInsteadOfRestartedForever() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        await h.pass(30, hearing: [.you])
        h.scheduler.fireAll()
        await eventually { h.controller.status == "Listening (on-device)" }
        let eventsAfterRestart = h.systemAudio.events

        await h.pass(30, hearing: [.you])

        XCTAssertEqual(h.controller.problems.map(\.message),
                       ["No audio is coming from the meeting. If people are talking, stop and start listening."])
        XCTAssertEqual(h.controller.status, "Listening (on-device)")
        await h.pass(300, hearing: [.you])
        XCTAssertEqual(h.systemAudio.events, eventsAfterRestart, "no restart loop while it is merely quiet")
        XCTAssertEqual(h.controller.problems.count, 1)
    }

    func testAudioComingBackClearsTheSilenceReport() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        await h.pass(30, hearing: [.you])
        h.scheduler.fireAll()
        await eventually { h.controller.status == "Listening (on-device)" }
        await h.pass(30, hearing: [.you])
        XCTAssertEqual(h.controller.problems.count, 1)

        await h.pass(5, hearing: [.you, .them])

        XCTAssertEqual(h.controller.problems, [])
    }

    func testASilentMicrophoneThatStaysSilentIsReportedAfterOneReconnect() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        await h.pass(120, hearing: [.them])

        XCTAssertEqual(h.microphone.reconnects, 1)
        XCTAssertEqual(h.controller.problems.map(\.message),
                       ["No audio is coming from your microphone. Check its input in System Settings, then stop and start listening."])
    }

    func testBothSidesHearingAudioNeverTriggersAnything() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        await h.pass(600, hearing: [.you, .them])

        XCTAssertEqual(h.systemAudio.events, ["start", "started"])
        XCTAssertEqual(h.microphone.reconnects, 0)
        XCTAssertEqual(h.controller.problems, [])
        XCTAssertEqual(h.transcribers.latest(.them)?.stops, 0)
    }

    func testASideThatIsAlreadyReconnectingIsNotJudgedAgain() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onError?("The display went to sleep")

        await h.pass(120, hearing: [.you])

        XCTAssertEqual(h.scheduler.delays, [1], "one pending restart, not one per check")
        XCTAssertEqual(h.systemAudio.events, ["start", "started"])
    }

    func testASideThatFailedIsNotWatched() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onError?(CaptureFailure(message: "The user stopped the stream", isRetryable: false))
        await eventually { h.systemAudio.events.last == "stopped" }

        await h.pass(120, hearing: [.you])

        XCTAssertEqual(h.systemAudio.events, ["start", "started", "stop", "stopped"])
        XCTAssertEqual(h.controller.problems.map(\.message), ["Meeting audio stopped: The user stopped the stream"])
    }

    func testAClockJumpLikeASleepIsNotMistakenForSilence() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        await h.pass(10, hearing: [.you, .them])

        h.clock.now = h.clock.now.addingTimeInterval(3_600)
        h.watchdogScheduler.fireAll()
        await h.mainQueueDrained()
        XCTAssertEqual(h.systemAudio.events, ["start", "started"])
        XCTAssertEqual(h.microphone.reconnects, 0)

        await h.pass(25, hearing: [.you])
        XCTAssertEqual(h.controller.status, "Listening (on-device)", "the count starts again after the jump")
        await h.pass(5, hearing: [.you])
        XCTAssertEqual(h.controller.status, "Listening (on-device, reconnecting their side)")
    }

    func testTheLevelFallsToZeroWhenAudioStopsArriving() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onBuffer?(tone(amplitude: 0.1))
        await eventually { h.controller.levels.them > 0 }

        await h.pass(5, hearing: [.you])
        XCTAssertGreaterThan(h.controller.levels.them, 0, "that buffer arrived within the first interval")
        await h.pass(5, hearing: [.you])

        XCTAssertEqual(h.controller.levels.them, 0)
    }

    // MARK: - A voice that is never written down (M1)

    func testAMinuteOfSpeechAndNoTextRestartsThatTranscriberOnce() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let them = h.transcribers.latest(.them)

        await h.pass(55, hearing: [.you], talking: [.them])
        XCTAssertEqual(them?.stops, 0)
        await h.pass(5, hearing: [.you], talking: [.them])

        XCTAssertEqual(them?.stops, 1)
        XCTAssertEqual(them?.starts, 2)
        XCTAssertEqual(h.transcribers.latest(.you)?.stops, 0, "your side was not the one that failed")
        XCTAssertEqual(h.controller.problems, [])
        XCTAssertEqual(h.systemAudio.events, ["start", "started"], "capture itself is fine")
    }

    func testStillNothingAfterTheRestartIsReportedOnceAndLeftRunning() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let them = h.transcribers.latest(.them)

        await h.pass(300, hearing: [.you], talking: [.them])

        XCTAssertEqual(them?.stops, 1, "restarted once, not every minute")
        XCTAssertEqual(h.controller.problems.map(\.message),
                       ["Their side is being heard but nothing is being transcribed. Stop and start listening to try again."])
        XCTAssertEqual(h.controller.status, "Listening (on-device)")
    }

    func testYourSidesSilentTranscriberIsNamedAsYours() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        await h.pass(120, hearing: [.them], talking: [.you])

        XCTAssertEqual(h.transcribers.latest(.you)?.stops, 1)
        XCTAssertEqual(h.controller.problems.map(\.message),
                       ["Your side is being heard but nothing is being transcribed. Stop and start listening to try again."])
    }

    func testTextAfterTheReportClearsIt() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        await h.pass(120, hearing: [.you], talking: [.them])
        XCTAssertEqual(h.controller.problems.count, 1)

        h.transcribers.latest(.them)?.emit("Sorry, I was on mute.")

        XCTAssertEqual(h.controller.problems, [])
    }

    func testTranscribedSpeechNeverTriggersARestart() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let them = h.transcribers.latest(.them)

        for _ in 0..<20 {
            await h.pass(30, hearing: [.you], talking: [.them])
            them?.emit("Still talking")
        }

        XCTAssertEqual(them?.stops, 0)
        XCTAssertEqual(h.controller.problems, [])
    }

    func testRoomNoiseWithoutSpeechNeverTriggersARestart() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        await h.pass(600, hearing: [.you, .them])

        XCTAssertEqual(h.transcribers.latest(.them)?.stops, 0)
        XCTAssertEqual(h.transcribers.latest(.you)?.stops, 0)
    }

    // MARK: - Never during a stop (M1)

    func testNothingFiresAfterAUserStop() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        await h.pass(20, hearing: [.you])

        h.controller.stop()
        await eventually { h.systemAudio.events.last == "stopped" }
        await h.pass(300, talking: [.them])

        XCTAssertEqual(h.systemAudio.events, ["start", "started", "stop", "stopped"])
        XCTAssertEqual(h.microphone.reconnects, 0)
        XCTAssertEqual(h.transcribers.latest(.them)?.stops, 1, "the stop itself, nothing from a watchdog")
        XCTAssertEqual(h.controller.problems, [])
        XCTAssertEqual(h.controller.status, "Stopped")
    }

    func testTheCheckStopsRescheduleItselfOnceTheSessionIsOver() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        XCTAssertEqual(h.watchdogScheduler.delays, [AssistantController.watchdogInterval])
        h.controller.stop()

        h.watchdogScheduler.fireAll()
        await h.mainQueueDrained()

        XCTAssertEqual(h.watchdogScheduler.delays, [])
    }

    func testACheckFromAnEarlierSessionCannotActOnTheNewOne() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.controller.stop()
        await h.startListening()
        XCTAssertEqual(h.watchdogScheduler.delays.count, 2, "one pending check per session")

        h.watchdogScheduler.fireAll()
        await h.mainQueueDrained()

        XCTAssertEqual(h.watchdogScheduler.delays.count, 1, "the old session's check ended, the new one carries on")
    }

    func testALateRestartFromTheWatchdogAfterAStopDoesNothing() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        await h.pass(30, hearing: [.you])
        XCTAssertEqual(h.controller.status, "Listening (on-device, reconnecting their side)")

        h.controller.stop()
        h.scheduler.fireAll()
        await settle()

        XCTAssertEqual(h.systemAudio.events, ["start", "started", "stop", "stopped"])
    }
}

