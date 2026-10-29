import XCTest

/// Auto-answer never silently drops a question: one asked while an answer is
/// still streaming (or inside the pause between auto-answers) waits its turn.
@MainActor
final class AssistantControllerQuestionTests: XCTestCase {
    // MARK: - Waiting for the answer in progress

    func testAQuestionAskedWhileAnAnswerIsStreamingIsAnsweredWhenItFinishes() async {
        let h = makeHarness()
        await startListening(h)
        h.them.emit("What's the plan?", utterance: 0)
        h.clock.now += 10

        h.them.emit("And who owns it?", utterance: 1)
        XCTAssertEqual(h.answerer.requests.count, 1, "the first answer is still streaming")
        h.answerer.streams[0].yield("- Ship in May")
        h.answerer.streams[0].finish()

        await eventually { h.answerer.requests.count == 2 }
        XCTAssertTrue(h.answerer.requests[1].user.contains("Them: What's the plan? And who owns it?"))
        XCTAssertNil(h.controller.answerNote)
    }

    func testOnlyTheMostRecentWaitingQuestionIsAnswered() async {
        let h = makeHarness()
        await startListening(h)
        h.them.emit("What's the plan?", utterance: 0)
        h.clock.now += 8
        h.them.emit("And who owns it?", utterance: 1)
        h.clock.now += 2
        h.them.emit("When do we start?", utterance: 2)

        h.answerer.streams[0].finish()
        await eventually { h.answerer.requests.count == 2 }
        h.answerer.streams[1].finish()
        await settle()

        XCTAssertEqual(h.answerer.requests.count, 2)
        XCTAssertTrue(h.answerer.requests[1].user.hasSuffix("Based on the latest exchange, give me help right now. Be concise."))
        XCTAssertTrue(h.answerer.requests[1].user.contains("When do we start?"))
    }

    func testAQuestionStillWaitingAfterThirtySecondsIsDroppedWithAQuietNote() async {
        let h = makeHarness()
        await startListening(h)
        h.them.emit("What's the plan?", utterance: 0)
        h.clock.now += 10
        h.them.emit("And who owns it?", utterance: 1)
        h.answerer.streams[0].yield("- Ship in May")
        h.clock.now += 40

        h.answerer.streams[0].finish()
        await eventually { !h.controller.isAnswering }

        XCTAssertEqual(h.answerer.requests.count, 1)
        XCTAssertEqual(h.controller.answerNote, "Skipped a question from 40s ago: \"And who owns it?\"")
        XCTAssertEqual(h.controller.answer, "- Ship in May")
    }

    func testAQuestionExactlyThirtySecondsOldIsStillAnswered() async {
        let h = makeHarness()
        await startListening(h)
        h.them.emit("What's the plan?", utterance: 0)
        h.clock.now += 10
        h.them.emit("And who owns it?", utterance: 1)
        h.clock.now += 30

        h.answerer.streams[0].finish()

        await eventually { h.answerer.requests.count == 2 }
        XCTAssertNil(h.controller.answerNote)
    }

    func testAFailedAnswerStillLetsTheWaitingQuestionThrough() async {
        let h = makeHarness()
        await startListening(h)
        h.them.emit("What's the plan?", utterance: 0)
        h.clock.now += 10
        h.them.emit("And who owns it?", utterance: 1)

        h.answerer.streams[0].finish(throwing: AnthropicError.midStream("Overloaded"))

        await eventually { h.answerer.requests.count == 2 }
    }

    // MARK: - The pause between auto-answers

    func testAQuestionHeldBackByThePauseIsAnsweredWhenThePauseEnds() async {
        let h = makeHarness()
        await startListening(h)
        h.them.emit("What's the plan?", utterance: 0)
        h.answerer.streams[0].finish()
        await eventually { !h.controller.isAnswering }
        h.clock.now += 3

        h.them.emit("And the budget?", utterance: 1)
        XCTAssertEqual(h.answerer.requests.count, 1)
        XCTAssertTrue(h.scheduler.delays.contains(3))
        h.clock.now += 3
        h.scheduler.fire(delay: 3)

        await eventually { h.answerer.requests.count == 2 }
        XCTAssertTrue(h.answerer.requests[1].user.contains("And the budget?"))
    }

    // MARK: - When a waiting question no longer matters

    func testAManualAnswerReplacesTheWaitingQuestion() async {
        let h = makeHarness()
        await startListening(h)
        h.them.emit("What's the plan?", utterance: 0)
        h.clock.now += 10
        h.them.emit("And who owns it?", utterance: 1)

        h.controller.answerNow()
        h.answerer.streams[1].finish()
        await eventually { !h.controller.isAnswering }
        await settle()

        XCTAssertEqual(h.answerer.requests.count, 2)
    }

    func testStoppingDropsTheWaitingQuestionWithoutANote() async {
        let h = makeHarness()
        await startListening(h)
        h.them.emit("What's the plan?", utterance: 0)
        h.clock.now += 10
        h.them.emit("And who owns it?", utterance: 1)

        h.controller.stop()
        h.answerer.streams[0].finish()
        await eventually { !h.controller.isAnswering }
        await settle()

        XCTAssertEqual(h.answerer.requests.count, 1)
        XCTAssertNil(h.controller.answerNote)
    }

    func testTurningAutoAnswerOffDropsTheWaitingQuestion() async {
        let h = makeHarness()
        await startListening(h)
        h.them.emit("What's the plan?", utterance: 0)
        h.clock.now += 10
        h.them.emit("And who owns it?", utterance: 1)

        h.settings.autoAnswer = false
        h.answerer.streams[0].finish()
        await eventually { !h.controller.isAnswering }
        await settle()

        XCTAssertEqual(h.answerer.requests.count, 1)
    }

    func testAWaitingQuestionDoesNotCarryIntoTheNextCall() async {
        let h = makeHarness()
        await startListening(h)
        h.them.emit("What's the plan?", utterance: 0)
        h.clock.now += 10
        h.them.emit("And who owns it?", utterance: 1)
        h.controller.stop()
        await startListening(h)

        h.answerer.streams[0].finish()
        await settle()

        XCTAssertEqual(h.answerer.requests.count, 1)
    }

    func testTheNoteGoesAwayWhenTheNextAnswerStarts() async {
        let h = makeHarness()
        await startListening(h)
        h.them.emit("What's the plan?", utterance: 0)
        h.clock.now += 10
        h.them.emit("And who owns it?", utterance: 1)
        h.clock.now += 40
        h.answerer.streams[0].finish()
        await eventually { h.controller.answerNote != nil }

        h.controller.answerNow()

        XCTAssertNil(h.controller.answerNote)
    }

    func testALongQuestionIsShortenedInTheNote() async {
        let h = makeHarness()
        await startListening(h)
        h.them.emit("What's the plan?", utterance: 0)
        h.clock.now += 10
        h.them.emit("Could you walk me through every single step of the migration plan again from the very beginning?",
                    utterance: 1)
        h.clock.now += 40

        h.answerer.streams[0].finish()
        await eventually { h.controller.answerNote != nil }

        let note = h.controller.answerNote ?? ""
        XCTAssertTrue(note.hasPrefix("Skipped a question from 40s ago: \"Could you walk me through"), note)
        XCTAssertTrue(note.hasSuffix("…\""), note)
        XCTAssertLessThanOrEqual(note.count, 90)
    }

    // MARK: - Harness

    private struct Harness {
        let controller: AssistantController
        let settings: AppSettings
        let systemAudio: FakeSystemAudio
        let transcribers: FakeTranscriberFactory
        let answerer: FakeAnswerer
        let clock: TestClock
        let scheduler: ManualScheduler

        var them: FakeTranscriber { transcribers.latest(.them)! }
    }

    private func makeHarness() -> Harness {
        let settings = makeTestSettings(for: self)
        settings.autoAnswer = true
        let systemAudio = FakeSystemAudio()
        let transcribers = FakeTranscriberFactory()
        let answerer = FakeAnswerer()
        let clock = TestClock()
        let scheduler = ManualScheduler()
        let controller = AssistantController(settings: settings, systemAudio: systemAudio, microphone: FakeMicrophone(),
                                             makeTranscriber: transcribers.make, answerer: answerer,
                                             now: { clock.now }, schedule: scheduler.schedule, sampleWordDelay: 0)
        return Harness(controller: controller, settings: settings, systemAudio: systemAudio,
                       transcribers: transcribers, answerer: answerer, clock: clock, scheduler: scheduler)
    }

    private func startListening(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) async {
        h.controller.start()
        await eventually(file: file, line: line) {
            h.controller.listening == .listening && h.systemAudio.events.last != "start"
        }
    }
}
