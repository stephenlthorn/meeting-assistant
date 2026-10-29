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
}
