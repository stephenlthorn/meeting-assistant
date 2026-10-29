import XCTest

/// Capture and transcription lifecycle: clearing, draining on stop, and
/// recovering from capture that dies mid-call.
@MainActor
final class AssistantControllerLifecycleTests: XCTestCase {
    // MARK: - Clearing the transcript

    func testWordsFromBeforeClearingDoNotComeBackWhenTheSpeakerKeepsTalking() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let them = h.transcribers.latest(.them)
        them?.emit("We should", utterance: 3, isFinal: false)

        h.controller.clearTranscript()
        them?.emit("We should ship in May", utterance: 3, isFinal: false)
        them?.emit("We should ship in May.", utterance: 3, isFinal: true)

        XCTAssertEqual(h.controller.transcriptText, "")
        them?.emit("Next point", utterance: 4)
        XCTAssertEqual(h.controller.transcriptText, "Them: Next point")
    }

    func testClearingOnlyHidesUtterancesOfTheSpeakerWhoWasInProgress() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.transcribers.latest(.them)?.emit("Go on", utterance: 3, isFinal: false)

        h.controller.clearTranscript()
        h.transcribers.latest(.you)?.emit("Sure", utterance: 0)

        XCTAssertEqual(h.controller.transcriptText, "You: Sure")
    }

    func testAFreshSessionAcceptsLowUtteranceNumbersAgainAfterAClear() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.transcribers.latest(.them)?.emit("Hello", utterance: 5)
        h.controller.clearTranscript()
        h.controller.stop()

        await h.startListening()
        h.transcribers.latest(.them)?.emit("Hi again", utterance: 0)

        XCTAssertEqual(h.controller.transcriptText, "Them: Hi again")
    }

    // MARK: - Notices (AUD-11)

    func testOneSpeakersNoticeClearingDoesNotWipeTheOthers() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let them = h.transcribers.latest(.them)
        let you = h.transcribers.latest(.you)

        them?.notice("Downloading the on-device speech model…")
        you?.notice("Downloading the on-device speech model…")
        XCTAssertEqual(h.controller.notice, "Downloading the on-device speech model…")

        you?.notice(nil)
        XCTAssertEqual(h.controller.notice, "Downloading the on-device speech model…")

        them?.notice(nil)
        XCTAssertNil(h.controller.notice)
    }

    func testDifferentNoticesFromBothSidesAreBothShown() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        h.transcribers.latest(.you)?.notice("Reconnecting to Deepgram…")
        h.transcribers.latest(.them)?.notice("Downloading the on-device speech model…")

        XCTAssertEqual(h.controller.notice,
                       "Downloading the on-device speech model…\nReconnecting to Deepgram…")
    }

    func testNoticesDoNotSurviveStopping() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.transcribers.latest(.them)?.notice("Downloading the on-device speech model…")

        h.controller.stop()
        await h.startListening()
        h.transcribers.latest(.you)?.notice(nil)

        XCTAssertNil(h.controller.notice)
    }

    // MARK: - Stopping (AUD-7)

    func testTheLastWordsOfACallStillArriveJustAfterStopping() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let them = h.transcribers.latest(.them)
        them?.emit("We should ship in", isFinal: false)

        h.controller.stop()
        them?.emit("We should ship in May.", isFinal: true)

        XCTAssertEqual(h.controller.transcriptText, "Them: We should ship in May.")
        XCTAssertEqual(h.controller.listening, .idle)
    }

    func testNothingIsAcceptedOnceTheDrainWindowIsOver() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let them = h.transcribers.latest(.them)
        them?.emit("We should ship in", isFinal: false)
        h.controller.stop()
        XCTAssertEqual(h.scheduler.delays, [AssistantController.defaultDrainWindow])

        h.scheduler.fireAll()
        await settle()
        them?.emit("We should ship in May.", isFinal: true)

        XCTAssertEqual(h.controller.transcriptText, "Them: We should ship in")
    }

    func testTheDrainWindowIsConfigurable() async {
        let h = LifecycleHarness(testCase: self, drainWindow: 0.25)
        await h.startListening()

        h.controller.stop()

        XCTAssertEqual(h.scheduler.delays, [0.25])
    }

    func testStartingAgainEndsTheDrainSoOldWordsNeverReachTheNewSession() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let oldThem = h.transcribers.latest(.them)
        h.controller.stop()

        await h.startListening()
        oldThem?.emit("stale words", isFinal: true)

        XCTAssertEqual(h.controller.transcriptText, "")
    }

    func testAWordAfterStoppingNeverStartsAnAutoAnswer() async {
        let h = LifecycleHarness(testCase: self)
        h.settings.autoAnswer = true
        await h.startListening()
        let them = h.transcribers.latest(.them)

        h.controller.stop()
        them?.emit("What's the timeline?", isFinal: true)

        XCTAssertEqual(h.controller.transcriptText, "Them: What's the timeline?")
        XCTAssertTrue(h.answerer.requests.isEmpty)
    }

    func testErrorsAndNoticesFromAStoppedSessionAreStillIgnored() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let them = h.transcribers.latest(.them)

        h.controller.stop()
        them?.fail("Late failure")
        them?.notice("Late notice")

        XCTAssertEqual(h.controller.problems, [])
        XCTAssertNil(h.controller.notice)
    }

    func testStoppingASampleMeetingSchedulesNoDrain() async {
        let h = LifecycleHarness(testCase: self)
        h.controller.startSample()
        h.scheduler.fireAll()
        await settle()

        h.controller.stop()

        XCTAssertFalse(h.scheduler.delays.contains(AssistantController.defaultDrainWindow))
    }

    // MARK: - System audio that dies mid-call (AUD-1, APP-2)

    func testAStreamThatDiesIsRestartedAndKeepsItsTranscriber() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let them = h.transcribers.latest(.them)

        h.systemAudio.onError?("The display went to sleep")
        XCTAssertEqual(h.controller.status, "Listening (on-device, reconnecting their side)")
        XCTAssertEqual(h.controller.listening, .listening)
        h.scheduler.fireAll()

        await eventually { h.systemAudio.events == ["start", "started", "stop", "stopped", "start", "started"] }
        await eventually { h.controller.status == "Listening (on-device)" }
        XCTAssertEqual(h.transcribers.latest(.them)?.stops, 0)
        XCTAssertEqual(h.transcribers.made.count, 2, "no new transcribers: numbering and state carry on")
        XCTAssertTrue(h.transcribers.latest(.them) === them)
        XCTAssertEqual(h.controller.problems, [])
    }

    func testAudioKeepsFlowingToTheSameTranscriberOnceItIsBack() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onError?("The display went to sleep")
        h.scheduler.fireAll()
        await eventually { h.systemAudio.events.count == 6 }

        h.systemAudio.onBuffer?(silentBuffer())

        XCTAssertEqual(h.transcribers.latest(.them)?.appended, 1)
    }

    func testRestartsBackOffAndThenGiveUpWithTheMicStillGoing() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onError?("The display went to sleep")
        h.systemAudio.startError = TestFailure(message: "No display available for capture.")

        for delay in AssistantController.systemAudioRetryDelays {
            XCTAssertEqual(h.scheduler.delays, [delay])
            XCTAssertEqual(h.controller.status, "Listening (on-device, reconnecting their side)")
            let failures = h.systemAudio.events.filter { $0 == "failed" }.count
            h.scheduler.fireAll()
            await eventually { h.systemAudio.events.filter { $0 == "failed" }.count == failures + 1 }
            await settle()
        }

        XCTAssertTrue(h.scheduler.delays.isEmpty)
        XCTAssertEqual(h.controller.status, "Listening (on-device, your side only)")
        XCTAssertEqual(h.controller.problems.map(\.message),
                       ["Meeting audio stopped and couldn't be restarted: No display available for capture."])
        XCTAssertEqual(h.transcribers.latest(.them)?.stops, 1)
        XCTAssertEqual(h.controller.listening, .listening)
        h.systemAudio.onBuffer?(silentBuffer())
        XCTAssertEqual(h.transcribers.latest(.them)?.appended, 0, "a side that gave up takes no more audio")
    }

    func testGivingUpWithTheMicAlreadyDownEndsTheSession() async {
        let h = LifecycleHarness(testCase: self)
        h.microphone.authorized = false
        await h.startListening()
        h.systemAudio.onError?("The display went to sleep")
        XCTAssertEqual(h.controller.status, "Reconnecting (on-device)")
        h.systemAudio.startError = TestFailure(message: "No display available for capture.")

        for _ in AssistantController.systemAudioRetryDelays {
            let failures = h.systemAudio.events.filter { $0 == "failed" }.count
            h.scheduler.fireAll()
            await eventually { h.systemAudio.events.filter { $0 == "failed" }.count == failures + 1 }
            await settle()
        }

        await eventually { h.controller.listening == .idle }
        XCTAssertEqual(h.controller.status, "Not listening")
    }

    func testStoppingSharingIsNotRestarted() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        h.systemAudio.onError?(CaptureFailure(message: "The user stopped the stream", isRetryable: false))

        XCTAssertTrue(h.scheduler.delays.isEmpty)
        XCTAssertEqual(h.controller.status, "Listening (on-device, your side only)")
        XCTAssertEqual(h.controller.problems.map(\.message), ["Meeting audio stopped: The user stopped the stream"])
        XCTAssertEqual(h.transcribers.latest(.them)?.stops, 1)
        await eventually { h.systemAudio.events.last == "stopped" }
    }

    func testAPermissionDeniedOnRestartIsNotRetried() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onError?("The display went to sleep")
        h.systemAudio.startError = SystemAudioError.permissionDenied

        h.scheduler.fireAll()

        await eventually { h.controller.status == "Listening (on-device, your side only)" }
        XCTAssertEqual(h.controller.problems.map(\.fix), [.screenRecording])
        XCTAssertTrue(h.scheduler.delays.isEmpty)
    }

    func testAStopWhileReconnectingCancelsTheRestart() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onError?("The display went to sleep")

        h.controller.stop()
        h.scheduler.fireAll()
        await settle()

        XCTAssertEqual(h.systemAudio.events, ["start", "started", "stop", "stopped"])
        XCTAssertEqual(h.controller.listening, .idle)
    }

    func testASecondErrorWhileReconnectingDoesNotScheduleAnotherRestart() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        h.systemAudio.onError?("The display went to sleep")
        h.systemAudio.onError?("The display went to sleep")

        XCTAssertEqual(h.scheduler.delays.count, 1)
    }

    func testALateErrorFromAnEarlierSessionCannotHitTheNewOne() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let oldHandler = h.systemAudio.onError
        h.controller.stop()
        await h.startListening()

        oldHandler?("The old stream finally noticed")

        XCTAssertEqual(h.controller.status, "Listening (on-device)")
        XCTAssertTrue(h.scheduler.delays.filter { $0 != AssistantController.defaultDrainWindow }.isEmpty)
        XCTAssertEqual(h.controller.problems, [])
    }

    func testAnErrorAfterStoppingIsIgnored() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.controller.stop()

        h.systemAudio.onError?("Stopped")

        XCTAssertEqual(h.controller.status, "Stopped")
        XCTAssertEqual(h.controller.problems, [])
    }

    // MARK: - Waking up and display changes

    func testWakingTheMacRestartsAReconnectingStreamAtOnce() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onError?("The display went to sleep")

        h.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)

        await eventually { h.systemAudio.events == ["start", "started", "stop", "stopped", "start", "started"] }
        await eventually { h.controller.status == "Listening (on-device)" }
        h.scheduler.fireAll()
        await settle()
        XCTAssertEqual(h.systemAudio.events.count, 6, "the pending backoff attempt is superseded")
    }

    func testAChangeOfDisplaysRestartsAReconnectingStream() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onError?("The display went to sleep")

        h.screenNotifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        await eventually { h.systemAudio.events.count == 6 }
    }

    func testAWakeAfterGivingUpBringsTheirSideBackWithTheSameTranscriber() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let them = h.transcribers.latest(.them)
        h.systemAudio.onError?("The display went to sleep")
        h.systemAudio.startError = TestFailure(message: "No display available for capture.")
        for _ in AssistantController.systemAudioRetryDelays {
            let failures = h.systemAudio.events.filter { $0 == "failed" }.count
            h.scheduler.fireAll()
            await eventually { h.systemAudio.events.filter { $0 == "failed" }.count == failures + 1 }
            await settle()
        }
        XCTAssertEqual(h.controller.status, "Listening (on-device, your side only)")
        h.systemAudio.startError = nil

        h.workspaceNotifications.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        await eventually { h.controller.status == "Listening (on-device)" }
        XCTAssertEqual(h.controller.problems, [], "the stale problem goes away once it works")
        XCTAssertTrue(h.transcribers.latest(.them) === them)
        XCTAssertEqual(them?.starts, 2)
        h.systemAudio.onBuffer?(silentBuffer())
        XCTAssertEqual(them?.appended, 1)
    }

    func testAWakeCannotUndoAPermissionProblemOrAUserStop() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onError?(CaptureFailure(message: "The user stopped the stream", isRetryable: false))
        await eventually { h.systemAudio.events.last == "stopped" }

        h.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle()

        XCTAssertEqual(h.systemAudio.events, ["start", "started", "stop", "stopped"])
        XCTAssertEqual(h.controller.status, "Listening (on-device, your side only)")
    }

    func testAWakeLeavesAHealthyStreamAlone() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        h.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        h.screenNotifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await settle()

        XCTAssertEqual(h.systemAudio.events, ["start", "started"])
    }

    func testWakingWhileNotListeningDoesNothing() async {
        let h = LifecycleHarness(testCase: self)

        h.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle()

        XCTAssertEqual(h.systemAudio.events, [])
    }

    // MARK: - The microphone dying mid-call (AUD-2, APP-2)

    func testAMicrophoneThatCannotBeRestartedLeavesTheirSideGoing() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        h.microphone.onError?("Couldn't restart after the input device changed: Device busy")

        XCTAssertEqual(h.controller.status, "Listening (on-device, their side only)")
        XCTAssertEqual(h.controller.problems.map(\.message),
                       ["Microphone stopped: Couldn't restart after the input device changed: Device busy"])
        XCTAssertEqual(h.transcribers.latest(.you)?.stops, 1)
        h.microphone.onBuffer?(silentBuffer())
        XCTAssertEqual(h.transcribers.latest(.you)?.appended, 0)
    }

    func testARecoveredMicrophoneComesBackWithItsTranscriber() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let you = h.transcribers.latest(.you)
        h.microphone.onError?("Device busy")

        h.microphone.onRecovered?()

        XCTAssertEqual(h.controller.status, "Listening (on-device)")
        XCTAssertEqual(h.controller.problems, [])
        XCTAssertEqual(you?.starts, 2)
        h.microphone.onBuffer?(silentBuffer())
        XCTAssertEqual(you?.appended, 1)
    }

    func testBothSidesDownEndsTheSession() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        h.systemAudio.onError?(CaptureFailure(message: "The user stopped the stream", isRetryable: false))
        h.microphone.onError?("Device busy")

        XCTAssertEqual(h.controller.listening, .idle)
        XCTAssertEqual(h.controller.status, "Not listening")
        await eventually { h.systemAudio.events.last == "stopped" }
        XCTAssertFalse(h.microphone.isRunning)
    }

    func testAMicrophoneErrorAfterStoppingOrFromAnEarlierSessionIsIgnored() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let oldError = h.microphone.onError
        h.controller.stop()
        await h.startListening()

        oldError?("Late")
        h.microphone.onRecovered?()

        XCTAssertEqual(h.controller.status, "Listening (on-device)")
        XCTAssertEqual(h.controller.problems, [])
    }
}
