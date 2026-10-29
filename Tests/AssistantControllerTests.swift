import XCTest

@MainActor
final class AssistantControllerTests: XCTestCase {
    // MARK: - Starting and stopping

    func testStartingListensToBothSidesAndNamesTheBackend() async {
        let h = makeHarness()

        h.controller.start()

        await eventually { h.controller.listening == .listening && h.systemAudio.isCapturing }
        XCTAssertEqual(h.controller.status, "Listening (on-device)")
        XCTAssertEqual(h.microphone.starts, 1)
        XCTAssertEqual(h.transcribers.latest(.them)?.starts, 1)
        XCTAssertEqual(h.transcribers.latest(.you)?.starts, 1)
    }

    func testTheStatusNamesACloudBackend() async {
        let h = makeHarness()
        h.transcribers.backendName = "Deepgram"

        await startListening(h)

        XCTAssertEqual(h.controller.status, "Listening (Deepgram)")
    }

    func testStartingAgainWhileStartingIsIgnored() async {
        let h = makeHarness()
        h.systemAudio.holdsStart = true

        h.controller.start()
        h.controller.start()
        await eventually { h.systemAudio.events == ["start"] }
        h.systemAudio.releaseStart()
        await eventually { h.controller.listening == .listening && h.systemAudio.isCapturing }

        XCTAssertEqual(h.transcribers.made.count, 2)
        XCTAssertEqual(h.microphone.starts, 1)
        XCTAssertEqual(h.systemAudio.events, ["start", "started"])
    }

    func testWithoutScreenRecordingItKeepsTheMicGoingAndSaysHowToFixIt() async {
        let h = makeHarness()
        h.systemAudio.startError = SystemAudioError.permissionDenied

        h.controller.start()
        await eventually { h.systemAudio.events.contains("failed") }

        XCTAssertEqual(h.controller.listening, .listening)
        XCTAssertEqual(h.controller.status, "Listening (on-device, your side only)")
        XCTAssertEqual(h.controller.problems.map(\.fix), [.screenRecording])
        XCTAssertEqual(h.transcribers.latest(.them)?.stops, 1)
    }

    func testStopWorksWhenOnlyTheMicStarted() async {
        let h = makeHarness()
        h.systemAudio.startError = SystemAudioError.permissionDenied
        h.controller.start()
        await eventually { h.systemAudio.events.contains("failed") }

        h.controller.stop()

        XCTAssertEqual(h.controller.listening, .idle)
        XCTAssertFalse(h.microphone.isRunning)
        XCTAssertEqual(h.transcribers.latest(.you)?.stops, 1)
    }

    func testWithoutMicrophoneAccessItListensToTheirSideAndSaysHowToFixIt() async {
        let h = makeHarness()
        h.microphone.authorized = false

        await startListening(h)

        XCTAssertEqual(h.controller.status, "Listening (on-device, their side only)")
        XCTAssertEqual(h.controller.problems.map(\.fix), [.microphone])
    }

    func testWhenNeitherSideStartsItGoesBackToIdle() async {
        let h = makeHarness()
        h.systemAudio.startError = SystemAudioError.permissionDenied
        h.microphone.authorized = false

        h.controller.start()
        await eventually { h.systemAudio.events.contains("failed") }

        XCTAssertEqual(h.controller.listening, .idle)
        XCTAssertEqual(h.controller.status, "Not listening")
        XCTAssertEqual(Set(h.controller.problems.compactMap(\.fix)), [.screenRecording, .microphone])
    }

    func testAMicrophoneThatFailsToStartIsReported() async {
        let h = makeHarness()
        h.microphone.startError = TestFailure(message: "No input device")

        await startListening(h)

        XCTAssertEqual(h.controller.status, "Listening (on-device, their side only)")
        XCTAssertEqual(h.controller.problems.map(\.message), ["Couldn't start the microphone: No input device"])
    }

    func testWithoutSpeechPermissionNothingIsCaptured() async {
        let h = makeHarness()
        h.transcribers.grantsAuthorization = false

        h.controller.start()
        await eventually { h.controller.listening == .idle }

        XCTAssertEqual(h.controller.problems.map(\.fix), [.speechRecognition])
        XCTAssertEqual(h.systemAudio.events, [])
        XCTAssertEqual(h.microphone.starts, 0)
    }

    func testStoppingStopsCaptureAndTranscription() async {
        let h = makeHarness()
        await startListening(h)

        h.controller.stop()
        await eventually { h.systemAudio.events.last == "stopped" }

        XCTAssertEqual(h.controller.listening, .idle)
        XCTAssertEqual(h.controller.status, "Stopped")
        XCTAssertFalse(h.microphone.isRunning)
        XCTAssertEqual(h.transcribers.latest(.them)?.stops, 1)
        XCTAssertEqual(h.transcribers.latest(.you)?.stops, 1)
    }

    func testRestartingWaitsForTheLastStopToFinish() async {
        let h = makeHarness()
        await startListening(h)
        h.systemAudio.holdsStop = true

        h.controller.stop()
        h.controller.start()
        await eventually { h.systemAudio.events.last == "stop" }
        await settle()
        XCTAssertEqual(h.systemAudio.events, ["start", "started", "stop"])

        h.systemAudio.releaseStop()
        await eventually { h.systemAudio.events.count == 6 }
        XCTAssertEqual(h.systemAudio.events, ["start", "started", "stop", "stopped", "start", "started"])
    }

    func testStoppingWhileSystemAudioIsStillStartingLeavesNothingCapturing() async {
        let h = makeHarness()
        h.systemAudio.holdsStart = true
        h.controller.start()
        await eventually { h.systemAudio.events == ["start"] }

        h.controller.stop()
        h.systemAudio.releaseStart()

        await eventually { h.systemAudio.events.last == "stopped" }
        XCTAssertFalse(h.systemAudio.isCapturing)
        XCTAssertEqual(h.controller.listening, .idle)
    }

    func testStartingANewSessionClearsTheLastOne() async {
        let h = makeHarness()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What's next?")
        h.controller.answerNow()
        h.controller.stop()

        await startListening(h)

        XCTAssertEqual(h.controller.transcriptDisplay, "")
        XCTAssertEqual(h.controller.answer, "")
        XCTAssertEqual(h.controller.problems, [])
    }

    // MARK: - Audio and transcript

    func testAudioReachesTheTranscribersOnlyWhileListening() async {
        let h = makeHarness()
        await startListening(h)
        let them = h.transcribers.latest(.them)
        let you = h.transcribers.latest(.you)

        h.systemAudio.onBuffer?(silentBuffer())
        h.microphone.onBuffer?(silentBuffer())
        h.controller.stop()
        h.systemAudio.onBuffer?(silentBuffer())
        h.microphone.onBuffer?(silentBuffer())

        XCTAssertEqual(them?.appended, 1)
        XCTAssertEqual(you?.appended, 1)
    }

    func testTheTranscriptShowsBothSidesInOrder() async {
        let h = makeHarness()
        await startListening(h)

        h.transcribers.latest(.them)?.emit("Hi, how are you?")
        h.transcribers.latest(.you)?.emit("Good, thanks.")

        XCTAssertEqual(h.controller.transcriptDisplay, "Them: Hi, how are you?\nYou: Good, thanks.")
        XCTAssertEqual(h.controller.transcriptText, "Them: Hi, how are you?\nYou: Good, thanks.")
    }

    func testSegmentsFromAStoppedSessionAreIgnored() async {
        let h = makeHarness()
        await startListening(h)
        let oldThem = h.transcribers.latest(.them)
        h.controller.stop()
        await startListening(h)

        oldThem?.emit("stale words")

        XCTAssertEqual(h.controller.transcriptDisplay, "")
    }

    func testClearingTheTranscriptEmptiesIt() async {
        let h = makeHarness()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("Hello.")

        h.controller.clearTranscript()

        XCTAssertEqual(h.controller.transcriptDisplay, "")
        XCTAssertEqual(h.controller.transcriptText, "")
    }

    func testTranscriberErrorsShowAsProblemsForThatSide() async {
        let h = makeHarness()
        await startListening(h)

        h.transcribers.latest(.them)?.fail("Speech model missing")

        XCTAssertEqual(h.controller.problems.map(\.message), ["Them: Speech model missing"])
    }

    func testCaptureErrorsShowAsProblems() async {
        let h = makeHarness()
        await startListening(h)

        h.systemAudio.onError?("The display went to sleep")

        XCTAssertEqual(h.controller.problems.map(\.message), ["Meeting audio stopped: The display went to sleep"])
    }

    func testTranscriberNoticesShowAndClear() async {
        let h = makeHarness()
        await startListening(h)

        h.transcribers.latest(.them)?.notice("Downloading the speech model…")
        XCTAssertEqual(h.controller.notice, "Downloading the speech model…")

        h.transcribers.latest(.them)?.notice(nil)
        XCTAssertNil(h.controller.notice)
    }

    // MARK: - Answers

    func testAnAnswerStreamsIntoTheOverlay() async {
        let h = makeHarness()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What's the timeline?")

        h.controller.answerNow()

        XCTAssertTrue(h.controller.isAnswering)
        let request = h.answerer.requests.first
        XCTAssertEqual(request?.apiKey, "sk-test")
        XCTAssertEqual(request?.model, "claude-haiku-4-5")
        XCTAssertEqual(request?.system, h.settings.systemPrompt)
        XCTAssertTrue(request?.user.contains("Them: What's the timeline?") ?? false)

        h.answerer.streams[0].yield("- Ship")
        h.answerer.streams[0].yield(" in May")
        h.answerer.streams[0].finish()
        await eventually { !h.controller.isAnswering }
        XCTAssertEqual(h.controller.answer, "- Ship in May")
    }

    func testAskingAgainReplacesTheAnswerWithoutAnError() async {
        let h = makeHarness()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What's the timeline?")

        h.controller.answerNow()
        h.controller.answerNow()
        h.answerer.streams[0].yield("stale")
        h.answerer.streams[0].finish(throwing: URLError(.cancelled))
        h.answerer.streams[1].yield("fresh")
        h.answerer.streams[1].finish()

        await eventually { !h.controller.isAnswering }
        await settle()
        XCTAssertEqual(h.controller.answer, "fresh")
    }

    func testAFailedAnswerSaysWhy() async {
        let h = makeHarness()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What's the timeline?")

        h.controller.answerNow()
        h.answerer.streams[0].finish(throwing: AnthropicError(message: "Rate limited by Anthropic (429). Wait a moment and try again."))

        await eventually { !h.controller.isAnswering }
        XCTAssertEqual(h.controller.answer, "Error: Rate limited by Anthropic (429). Wait a moment and try again.")
    }

    func testAnAnswerThatFailsHalfwayKeepsWhatArrived() async {
        let h = makeHarness()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What's the timeline?")

        h.controller.answerNow()
        h.answerer.streams[0].yield("- First point")
        h.answerer.streams[0].finish(throwing: AnthropicError.midStream("Overloaded"))

        await eventually { !h.controller.isAnswering }
        XCTAssertEqual(h.controller.answer, "- First point\n\nError: Claude stopped mid-answer: Overloaded")
    }

    func testAskingWithoutATranscriptExplainsWhy() {
        let h = makeHarness()

        h.controller.answerNow()

        XCTAssertEqual(h.controller.answer, "No transcript yet. Start listening first.")
        XCTAssertTrue(h.answerer.requests.isEmpty)
    }

    func testAskingWithoutAKeyExplainsWhereToAddIt() async {
        let h = makeHarness(secrets: InMemorySecretStore())
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What's the timeline?")

        h.controller.answerNow()

        XCTAssertEqual(h.controller.answer, "No API key. Add one in Settings (menu bar icon, then Settings…).")
        XCTAssertTrue(h.answerer.requests.isEmpty)
    }

    // MARK: - Auto-answer

    func testTheirQuestionGetsAnAutomaticAnswer() async {
        let h = makeHarness()
        h.settings.autoAnswer = true
        await startListening(h)

        h.transcribers.latest(.them)?.emit("What's the timeline?")

        XCTAssertEqual(h.answerer.requests.count, 1)
    }

    func testAutoAnswerIgnoresPartialsMyQuestionsAndStatements() async {
        let h = makeHarness()
        h.settings.autoAnswer = true
        await startListening(h)

        h.transcribers.latest(.them)?.emit("What's the time", utterance: 0, isFinal: false)
        h.transcribers.latest(.you)?.emit("What's the timeline?")
        h.transcribers.latest(.them)?.emit("We ship in May.", utterance: 1)

        XCTAssertTrue(h.answerer.requests.isEmpty)
    }

    func testAutoAnswerWaitsBetweenAnswers() async {
        let h = makeHarness()
        h.settings.autoAnswer = true
        await startListening(h)
        let them = h.transcribers.latest(.them)

        them?.emit("What's the plan?", utterance: 0)
        h.answerer.streams[0].finish()
        await eventually { !h.controller.isAnswering }
        h.clock.now += 3
        them?.emit("And the budget?", utterance: 1)
        XCTAssertEqual(h.answerer.requests.count, 1)

        h.clock.now += 4
        them?.emit("And who owns it?", utterance: 2)
        XCTAssertEqual(h.answerer.requests.count, 2)
    }

    func testAutoAnswerDoesNotInterruptAnAnswerInProgress() async {
        let h = makeHarness()
        h.settings.autoAnswer = true
        await startListening(h)
        h.transcribers.latest(.them)?.emit("Let me share some context.", utterance: 0)
        h.controller.answerNow()

        h.clock.now += 60
        h.transcribers.latest(.them)?.emit("Does that make sense?", utterance: 1)

        XCTAssertEqual(h.answerer.requests.count, 1)
    }

    func testWithAutoAnswerOffTheirQuestionsWait() async {
        let h = makeHarness()
        await startListening(h)

        h.transcribers.latest(.them)?.emit("What's the timeline?")

        XCTAssertTrue(h.answerer.requests.isEmpty)
    }

    // MARK: - Privacy terms

    func testListeningWaitsForThePrivacyTerms() async {
        let h = makeHarness(acceptTerms: false)
        var asked = 0
        h.controller.onTermsNeeded = { _ in asked += 1 }

        h.controller.start()
        await settle()

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(h.controller.listening, .idle)
        XCTAssertEqual(h.systemAudio.events, [])
        XCTAssertEqual(h.microphone.starts, 0)
    }

    func testAcceptingTheTermsCarriesOnWithWhatWasAsked() async {
        let h = makeHarness(acceptTerms: false)
        var resume: (() -> Void)?
        h.controller.onTermsNeeded = { resume = $0 }
        h.controller.start()

        h.settings.acceptTerms()
        resume?()

        await eventually { h.controller.listening == .listening }
    }

    func testAnswersWaitForThePrivacyTerms() {
        let h = makeHarness(acceptTerms: false)
        var asked = 0
        h.controller.onTermsNeeded = { _ in asked += 1 }

        h.controller.answerNow()

        XCTAssertEqual(asked, 1)
        XCTAssertTrue(h.answerer.requests.isEmpty)
    }

    // MARK: - Sample meeting

    func testTheSampleMeetingPlaysItsScriptWithoutRecording() async {
        let h = makeHarness()

        h.controller.startSample()
        XCTAssertEqual(h.controller.listening, .sample)
        XCTAssertEqual(h.controller.status, "Sample meeting (nothing is recorded)")
        await advanceSample(h, lines: 3)

        let expected = SampleMeeting.lines.prefix(3).map { "\($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
        XCTAssertEqual(h.controller.transcriptText, expected)
        XCTAssertEqual(h.systemAudio.events, [])
        XCTAssertEqual(h.microphone.starts, 0)
        XCTAssertTrue(h.transcribers.made.isEmpty)
    }

    func testTheSampleMeetingShowsSampleAnswersWithoutAKey() async {
        let h = makeHarness(secrets: InMemorySecretStore())

        h.controller.startSample()
        await advanceSample(h, lines: firstSampleQuestion + 1)

        await eventually { !h.controller.isAnswering && !h.controller.answer.isEmpty }
        XCTAssertTrue(h.controller.answer.hasPrefix("Sample answer"), h.controller.answer)
        XCTAssertTrue(h.answerer.requests.isEmpty)
    }

    func testTheSampleMeetingAsksClaudeWhenThereIsAKey() async {
        let h = makeHarness()

        h.controller.startSample()
        await advanceSample(h, lines: firstSampleQuestion + 1)

        XCTAssertEqual(h.answerer.requests.count, 1)
        XCTAssertTrue(h.answerer.requests.first?.user.contains(SampleMeeting.lines[firstSampleQuestion].text) ?? false)
    }

    func testTheSampleMeetingWorksBeforeThePrivacyTermsAreAccepted() async {
        let h = makeHarness(acceptTerms: false, secrets: InMemorySecretStore())
        var asked = 0
        h.controller.onTermsNeeded = { _ in asked += 1 }

        h.controller.startSample()
        await advanceSample(h, lines: firstSampleQuestion + 1)

        await eventually { !h.controller.isAnswering && !h.controller.answer.isEmpty }
        XCTAssertTrue(h.controller.answer.hasPrefix("Sample answer"))
        XCTAssertEqual(asked, 0)
    }

    func testStoppingEndsTheSampleMeeting() async {
        let h = makeHarness()
        h.controller.startSample()
        await advanceSample(h, lines: 1)

        h.controller.stop()
        h.scheduler.fireAll()
        await settle()

        XCTAssertEqual(h.controller.listening, .idle)
        XCTAssertEqual(h.controller.transcriptText, "Them: \(SampleMeeting.lines[0].text)")
    }

    func testTheSampleMeetingFinishesByItself() async {
        let h = makeHarness()

        h.controller.startSample()
        await advanceSample(h, lines: SampleMeeting.lines.count)

        await eventually { h.controller.listening == .idle }
        XCTAssertEqual(h.controller.status, "Sample meeting finished")
    }

    func testASampleMeetingWaitsUntilListeningStops() async {
        let h = makeHarness()
        await startListening(h)

        h.controller.startSample()

        XCTAssertEqual(h.controller.listening, .listening)
        XCTAssertTrue(h.scheduler.delays.isEmpty)
    }

    // MARK: - Harness

    private struct Harness {
        let controller: AssistantController
        let settings: AppSettings
        let systemAudio: FakeSystemAudio
        let microphone: FakeMicrophone
        let transcribers: FakeTranscriberFactory
        let answerer: FakeAnswerer
        let clock: TestClock
        let scheduler: ManualScheduler
    }

    private func makeHarness(acceptTerms: Bool = true,
                             secrets: InMemorySecretStore = InMemorySecretStore(values: ["anthropic_api_key": "sk-test"]))
        -> Harness {
        let settings = makeTestSettings(for: self, secrets: secrets, acceptTerms: acceptTerms)
        let systemAudio = FakeSystemAudio()
        let microphone = FakeMicrophone()
        let transcribers = FakeTranscriberFactory()
        let answerer = FakeAnswerer()
        let clock = TestClock()
        let scheduler = ManualScheduler()
        let controller = AssistantController(settings: settings, systemAudio: systemAudio, microphone: microphone,
                                             makeTranscriber: transcribers.make, answerer: answerer,
                                             now: { clock.now }, schedule: scheduler.schedule,
                                             sampleWordDelay: 0)
        return Harness(controller: controller, settings: settings, systemAudio: systemAudio,
                       microphone: microphone, transcribers: transcribers, answerer: answerer, clock: clock,
                       scheduler: scheduler)
    }

    private func startListening(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) async {
        h.controller.start()
        await eventually(file: file, line: line) {
            h.controller.listening == .listening && h.systemAudio.events.last != "start"
        }
    }

    private var firstSampleQuestion: Int {
        SampleMeeting.lines.firstIndex { $0.speaker == .them && QuestionDetector.looksLikeQuestion($0.text) }!
    }

    /// Lets the sample meeting show its next `lines` lines, one scheduled step at a time.
    private func advanceSample(_ h: Harness, lines: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<lines {
            h.scheduler.fireAll()
            await eventually(file: file, line: line) {
                !h.scheduler.delays.isEmpty || h.controller.listening != .sample
            }
        }
    }
}
