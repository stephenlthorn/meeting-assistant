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
}
