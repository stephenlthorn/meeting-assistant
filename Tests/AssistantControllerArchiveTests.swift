import XCTest

/// Saving transcripts (M3) and keeping a long meeting bounded (M6) through the
/// real controller. The harness is its own so this file evolves independently.
@MainActor
final class AssistantControllerArchiveTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/Notes/Calls", isDirectory: true)

    // MARK: - Saving as the call goes

    func testNothingIsSavedUnlessTheUserTurnedSavingOn() async {
        let h = makeHarness(saving: false)
        await startListening(h)

        h.transcribers.latest(.them)?.emit("What's the plan for Friday?")
        h.controller.stop()

        XCTAssertEqual(h.files.writes, [])
        XCTAssertFalse(h.scheduler.delays.contains(AssistantController.archiveInterval))
    }

    func testTheFolderIsPreparedWhenTheCallStartsSoAProblemShowsThenNotThirtySecondsIn() async {
        let h = makeHarness()
        h.files.failure = TestFailure(message: "The folder can't be created")

        h.controller.start()

        XCTAssertEqual(h.controller.problems.map(\.message), ["Couldn't save the transcript: The folder can't be created"])
        await eventually { h.controller.listening == .listening }
    }

    func testTheFolderIsCreatedAtStartWhenSavingIsOnAndNotWhenItIsOff() async {
        let on = makeHarness(saving: true)
        await startListening(on)
        let off = makeHarness(saving: false)
        await startListening(off)

        XCTAssertEqual(on.files.prepared, [folder])
        XCTAssertEqual(off.files.prepared, [])
    }

    func testQuittingMidCallSavesWhatWasSaidSinceTheLastWrite() async {
        let h = makeHarness()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("Said just before the quit.", utterance: 0)

        h.controller.saveBeforeQuit()

        XCTAssertTrue(savedText(h).contains("Said just before the quit."))
    }

    func testTheTranscriptIsWrittenEveryThirtySeconds() async {
        let h = makeHarness()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What's the plan for Friday?", utterance: 0)
        XCTAssertEqual(h.files.writes, [], "nothing is written before the first interval")
        XCTAssertTrue(h.scheduler.delays.contains(30))

        h.scheduler.fire(delay: 30)
        await eventually { !h.files.writes.isEmpty }
        XCTAssertTrue(savedText(h).contains("Them: What's the plan for Friday?"))

        h.transcribers.latest(.you)?.emit("We ship in May.", utterance: 0)
        h.scheduler.fire(delay: 30)
        await eventually { savedText(h).contains("You: We ship in May.") }
        XCTAssertTrue(h.scheduler.delays.contains(30), "the next write is already scheduled")
    }

    func testTheFileIsNamedByStartTimeInTheChosenFolder() async {
        let h = makeHarness()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("Hello there, team.")

        h.controller.stop()

        let stem = TranscriptMarkdown().fileStem(started: h.clock.now)
        XCTAssertEqual(h.files.onlyFile?.url, folder.appendingPathComponent(stem + ".md"))
        XCTAssertTrue(savedText(h).hasPrefix("# Meeting transcript\n\nStarted: "))
    }

    func testStoppingWritesTheTranscriptAtOnce() async {
        let h = makeHarness()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("Hello there, team.")

        h.controller.stop()

        XCTAssertTrue(savedText(h).contains("Them: Hello there, team."))
    }

    func testWordsHeardInTheDrainWindowAreSavedWhenItCloses() async {
        let h = makeHarness()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("Hello there, team.", utterance: 0)
        h.controller.stop()

        h.transcribers.latest(.them)?.emit("And one last thing.", utterance: 1)
        h.scheduler.fire(delay: AssistantController.defaultDrainWindow)

        await eventually { savedText(h).contains("And one last thing.") }
    }

    func testASentenceStillBeingSpokenIsSaved() async {
        let h = makeHarness()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("We should ship", utterance: 0, isFinal: false)

        h.scheduler.fire(delay: 30)

        await eventually { savedText(h).contains("Them: We should ship") }
    }

    func testTurningSavingOffMidCallStopsWritingAtOnce() async {
        let h = makeHarness()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("Before the switch.", utterance: 0)
        h.scheduler.fire(delay: 30)
        await eventually { !h.files.writes.isEmpty }
        let writes = h.files.writes.count

        h.settings.saveTranscripts = false
        h.transcribers.latest(.them)?.emit("After the switch.", utterance: 1)
        h.scheduler.fire(delay: 30)
        await settle()
        h.controller.stop()

        XCTAssertEqual(h.files.writes.count, writes)
        XCTAssertFalse(savedText(h).contains("After the switch."))
    }

    func testTurningSavingOnMidCallWaitsForTheNextStart() async {
        let h = makeHarness(saving: false)
        await startListening(h)
        h.transcribers.latest(.them)?.emit("Before the switch.", utterance: 0)

        h.settings.saveTranscripts = true
        h.scheduler.fire(delay: 30)
        h.controller.stop()

        XCTAssertEqual(h.files.writes, [])
    }

    func testTheSampleMeetingIsNeverSaved() async {
        let h = makeHarness()

        h.controller.startSample()
        h.scheduler.fireAll()
        await settle()
        h.controller.stop()

        XCTAssertEqual(h.files.writes, [])
    }

    func testClearingTheTranscriptKeepsWhatWasAlreadySaved() async {
        let h = makeHarness()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("Before the clear.", utterance: 0)

        h.controller.clearTranscript()
        h.transcribers.latest(.them)?.emit("After the clear.", utterance: 1)
        h.controller.stop()

        let text = savedText(h)
        XCTAssertTrue(text.contains("Them: Before the clear."), text)
        XCTAssertTrue(text.contains("Them: After the clear."), text)
    }

    func testAFolderThatCannotBeWrittenShowsAProblemAndRecovers() async {
        let h = makeHarness()
        await startListening(h)
        h.files.failure = TestFailure(message: "The disk is full")
        h.transcribers.latest(.them)?.emit("Important decision.", utterance: 0)

        h.scheduler.fire(delay: 30)
        await eventually { !h.controller.problems.isEmpty }
        XCTAssertEqual(h.controller.problems.map(\.message), ["Couldn't save the transcript: The disk is full"])

        h.files.failure = nil
        h.scheduler.fire(delay: 30)
        await eventually { h.controller.problems.isEmpty }
        XCTAssertTrue(savedText(h).contains("Important decision."))
    }

    func testAnOldSessionsTimerDoesNothingInTheNextSession() async {
        let h = makeHarness()
        await startListening(h)
        h.controller.stop()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("Only the new session.", utterance: 0)

        h.scheduler.fire(delay: 30)
        await eventually { !h.files.writes.isEmpty }

        XCTAssertEqual(h.files.files.count, 1)
        XCTAssertTrue(savedText(h).contains("Only the new session."))
    }

    // MARK: - Save Transcript...

    func testSaveTranscriptWritesTheTranscriptWhereTheUserChoseEvenWithSavingOff() async {
        let h = makeHarness(saving: false)
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What's the plan for Friday?", utterance: 0)
        h.transcribers.latest(.you)?.emit("We ship in May.", utterance: 0)
        let target = URL(fileURLWithPath: "/Users/me/Desktop/call.md")

        h.controller.saveTranscript(to: target)

        let text = h.files.text(at: target) ?? ""
        XCTAssertTrue(text.hasPrefix("# Meeting transcript\n\nStarted: "), text)
        XCTAssertTrue(text.contains("Them: What's the plan for Friday?\n"), text)
        XCTAssertTrue(text.contains("You: We ship in May.\n"), text)
    }

    func testSaveTranscriptStillWorksAfterTheCallEnded() async {
        let h = makeHarness(saving: false)
        await startListening(h)
        h.transcribers.latest(.them)?.emit("Hello there, team.")
        h.controller.stop()
        let target = URL(fileURLWithPath: "/Users/me/Desktop/call.md")

        h.controller.saveTranscript(to: target)

        XCTAssertTrue((h.files.text(at: target) ?? "").contains("Them: Hello there, team."))
    }

    func testSaveTranscriptGivesTheWholeSavedCallEvenAfterLinesWereTrimmed() async {
        let h = makeHarness()
        await startListening(h)
        talk(h, turns: 450)
        let target = URL(fileURLWithPath: "/Users/me/Desktop/call.md")

        h.controller.saveTranscript(to: target)

        let text = h.files.text(at: target) ?? ""
        XCTAssertTrue(text.contains("Budget review 0 is complete."), "the first line is in the saved copy")
        XCTAssertTrue(text.contains("Noted 449 alpha beta gamma."))
        XCTAssertFalse(text.contains("[earlier lines trimmed]"))
    }

    func testSaveTranscriptSaysSoWhenLinesWereTrimmedAndNothingWasSaved() async {
        let h = makeHarness(saving: false)
        await startListening(h)
        talk(h, turns: 450)
        let target = URL(fileURLWithPath: "/Users/me/Desktop/call.md")

        h.controller.saveTranscript(to: target)

        let text = h.files.text(at: target) ?? ""
        XCTAssertTrue(text.contains("[earlier lines trimmed]"), text)
        XCTAssertFalse(text.contains("Budget review 0 is complete."))
        XCTAssertTrue(text.contains("Noted 449 alpha beta gamma."))
    }

    func testASaveThatFailsShowsAProblem() async {
        let h = makeHarness(saving: false)
        await startListening(h)
        h.transcribers.latest(.them)?.emit("Hello there, team.")
        h.files.failure = TestFailure(message: "No permission")

        h.controller.saveTranscript(to: URL(fileURLWithPath: "/Users/me/Desktop/call.md"))

        XCTAssertEqual(h.controller.problems.map(\.message), ["Couldn't save the transcript: No permission"])
    }

    func testTheSuggestedNameIsTheStartTime() async {
        let h = makeHarness(saving: false)
        await startListening(h)

        XCTAssertEqual(h.controller.suggestedTranscriptFileName,
                       TranscriptMarkdown().fileStem(started: h.clock.now) + ".md")
    }

    // MARK: - Long meetings (M6)

    func testCopyTranscriptSaysEarlierLinesWereTrimmedOnceACallRunsLong() async {
        let h = makeHarness(saving: false)
        await startListening(h)

        talk(h, turns: 450)

        let text = h.controller.transcriptText
        XCTAssertTrue(text.hasPrefix("[earlier lines trimmed]\n"), String(text.prefix(80)))
        XCTAssertTrue(text.hasSuffix("Noted 449 alpha beta gamma."))
        XCTAssertFalse(text.contains("Budget review 0 is complete."))
    }

    func testWithSavingOnTheMarkerSaysWhereTheEarlierLinesAre() async {
        let h = makeHarness()
        await startListening(h)

        talk(h, turns: 450)

        XCTAssertTrue(h.controller.transcriptText.hasPrefix("[earlier lines trimmed - they are in your saved transcript file]\n"))
    }

    func testAnswersAndTheOverlayKeepWorkingOnTheRecentTranscript() async {
        let h = makeHarness(saving: false)
        await startListening(h)
        talk(h, turns: 450)

        h.controller.answerNow()

        let user = h.answerer.requests.first?.user ?? ""
        XCTAssertTrue(user.contains("Noted 449 alpha beta gamma."))
        XCTAssertFalse(user.contains("[earlier lines trimmed]"))
        XCTAssertTrue(h.controller.transcriptDisplay.hasSuffix("Noted 449 alpha beta gamma."))
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
        let files: FakeTranscriptFiles
    }

    private func makeHarness(saving: Bool = true) -> Harness {
        let settings = makeTestSettings(for: self)
        settings.saveTranscripts = saving
        settings.transcriptFolder = folder
        let systemAudio = FakeSystemAudio()
        let microphone = FakeMicrophone()
        let transcribers = FakeTranscriberFactory()
        let answerer = FakeAnswerer()
        let clock = TestClock()
        let scheduler = ManualScheduler()
        let files = FakeTranscriptFiles()
        let controller = AssistantController(settings: settings, systemAudio: systemAudio, microphone: microphone,
                                             makeTranscriber: transcribers.make, answerer: answerer,
                                             now: { clock.now }, schedule: scheduler.schedule,
                                             sampleWordDelay: 0, transcriptFiles: files)
        return Harness(controller: controller, settings: settings, systemAudio: systemAudio, microphone: microphone,
                       transcribers: transcribers, answerer: answerer, clock: clock, scheduler: scheduler, files: files)
    }

    private func startListening(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) async {
        h.controller.start()
        await eventually(file: file, line: line) {
            h.controller.listening == .listening && h.systemAudio.events.last != "start"
        }
    }

    private func savedText(_ h: Harness) -> String {
        h.files.files.first(where: { !$0.key.lastPathComponent.hasSuffix("-summary.md") })
            .flatMap { String(data: $0.value, encoding: .utf8) } ?? ""
    }

    /// Alternating sides, worded differently so the microphone never reads as an echo.
    private func talk(_ h: Harness, turns: Int) {
        for index in 0..<turns {
            if index.isMultiple(of: 2) {
                h.transcribers.latest(.them)?.emit("Budget review \(index) is complete.", utterance: index)
            } else {
                h.transcribers.latest(.you)?.emit("Noted \(index) alpha beta gamma.", utterance: index)
            }
        }
    }
}
