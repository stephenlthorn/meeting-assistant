import XCTest

@MainActor
final class TranscriptArchiveTests: XCTestCase {
    /// 2026-10-29 14:30:05 UTC.
    private let started = Date(timeIntervalSince1970: 1_793_284_205)
    private let folder = URL(fileURLWithPath: "/Notes/Meeting Assistant", isDirectory: true)
    private let format = TranscriptMarkdown(timeZone: TimeZone(identifier: "UTC")!)

    func testTheFirstFlushWritesTheHeaderAndTimestampedLines() throws {
        let h = makeHarness()
        say(h, "Hi, how are you?", from: .them, at: 0)
        say(h, "Good, thanks for asking.", from: .you, at: 4)

        XCTAssertTrue(h.archive.flush(snapshot: []))

        let file = try XCTUnwrap(h.files.onlyFile)
        XCTAssertEqual(file.url.path, "/Notes/Meeting Assistant/Meeting 2026-10-29 14-30-05.md")
        XCTAssertEqual(file.text, """
            # Meeting transcript

            Started: 2026-10-29 14:30:05

            - [14:30:05] Them: Hi, how are you?
            - [14:30:09] You: Good, thanks for asking.

            """)
    }

    func testNothingIsWrittenForACallThatHasNoWordsYet() {
        let h = makeHarness()

        XCTAssertTrue(h.archive.flush(snapshot: []))

        XCTAssertEqual(h.files.writes, [])
        XCTAssertFalse(h.archive.hasFile)
    }

    func testLaterFlushesAddLinesToTheSameFile() throws {
        let h = makeHarness()
        say(h, "First point.", from: .them, at: 0)
        h.archive.flush(snapshot: [])

        say(h, "A second point here.", from: .them, at: 30)
        h.archive.flush(snapshot: [])

        let text = try XCTUnwrap(h.files.onlyFile).text
        XCTAssertTrue(text.hasSuffix("- [14:30:05] Them: First point.\n- [14:30:35] Them: A second point here.\n"), text)
    }

    func testASentenceStillBeingSpokenIsSavedThenReplacedByItsFinalText() throws {
        let h = makeHarness()
        h.transcript.apply(TranscriptSegment(utterance: 0, text: "We should", isFinal: false), from: .them, at: started)
        h.archive.append(h.transcript.collectCommitted())
        h.archive.flush(snapshot: h.transcript.uncommittedTurns)
        XCTAssertTrue(try XCTUnwrap(h.files.onlyFile).text.hasSuffix("- [14:30:05] Them: We should\n"))

        say(h, "We should ship it on Friday.", from: .them, at: 0, utterance: 0)
        h.archive.flush(snapshot: h.transcript.uncommittedTurns)

        let text = try XCTUnwrap(h.files.onlyFile).text
        XCTAssertTrue(text.hasSuffix("Started: 2026-10-29 14:30:05\n\n- [14:30:05] Them: We should ship it on Friday.\n"), text)
    }

    func testLinesTrimmedFromMemoryAreStillInTheFile() throws {
        let h = makeHarness(limits: .init(maxTurns: 20, maxCharacters: 100_000, maxUncommitted: 8))

        for index in 0..<200 {
            say(h, "sentence \(index) of the review.", from: .them, at: TimeInterval(index), utterance: index)
            if index.isMultiple(of: 10) { h.archive.flush(snapshot: h.transcript.uncommittedTurns) }
        }
        h.archive.flush(snapshot: h.transcript.uncommittedTurns)

        XCTAssertLessThanOrEqual(h.transcript.retainedTurnCount, 20)
        let lines = try XCTUnwrap(h.files.onlyFile).text.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }
        XCTAssertEqual(lines.count, 200)
        XCTAssertTrue(lines.first?.hasSuffix("sentence 0 of the review.") ?? false)
        XCTAssertTrue(lines.last?.hasSuffix("sentence 199 of the review.") ?? false)
    }

    func testAFailedWriteIsReportedAndTheLinesAreKeptForTheNextTry() throws {
        let h = makeHarness()
        say(h, "Important decision.", from: .them, at: 0)
        h.files.failure = TestFailure(message: "The disk is full")

        XCTAssertFalse(h.archive.flush(snapshot: []))
        XCTAssertEqual(h.archive.lastError?.localizedDescription, "The disk is full")
        XCTAssertNil(h.files.onlyFile)

        h.files.failure = nil
        XCTAssertTrue(h.archive.flush(snapshot: []))

        XCTAssertNil(h.archive.lastError)
        XCTAssertTrue(try XCTUnwrap(h.files.onlyFile).text.contains("Important decision."))
    }

    func testAFileThatWasDeletedMidCallIsStartedAgainAndSaysSo() throws {
        let h = makeHarness()
        say(h, "Before the deletion.", from: .them, at: 0)
        h.archive.flush(snapshot: [])
        h.files.remove(h.archive.url)

        say(h, "After the deletion.", from: .them, at: 30)
        XCTAssertTrue(h.archive.flush(snapshot: []))

        let text = try XCTUnwrap(h.files.onlyFile).text
        XCTAssertTrue(text.contains("[earlier lines were not found when this file was updated]"), text)
        XCTAssertTrue(text.hasSuffix("- [14:30:35] Them: After the deletion.\n"), text)
        XCTAssertFalse(text.contains("Before the deletion."))
    }

    func testACallThatStartsInTheSameSecondDoesNotOverwriteAnEarlierFile() throws {
        let files = FakeTranscriptFiles()
        files.put("an earlier call", at: folder.appendingPathComponent("Meeting 2026-10-29 14-30-05.md"))
        let h = makeHarness(files: files)
        say(h, "Hello again.", from: .them, at: 0)

        h.archive.flush(snapshot: [])

        XCTAssertEqual(h.archive.url.lastPathComponent, "Meeting 2026-10-29 14-30-05 2.md")
        XCTAssertEqual(files.text(at: folder.appendingPathComponent("Meeting 2026-10-29 14-30-05.md")), "an earlier call")
    }

    func testTheBodyIsTheTranscriptWithoutItsHeader() throws {
        let h = makeHarness()
        say(h, "Hello.", from: .them, at: 0)
        XCTAssertNil(h.archive.body())

        h.archive.flush(snapshot: [])

        XCTAssertEqual(h.archive.body(), "- [14:30:05] Them: Hello.\n")
    }

    func testASummaryIsSavedNextToTheTranscript() throws {
        let h = makeHarness()
        say(h, "Hello.", from: .them, at: 0)
        h.archive.flush(snapshot: [])

        XCTAssertTrue(h.archive.saveSummary("- Decided to ship."))

        let summary = folder.appendingPathComponent("Meeting 2026-10-29 14-30-05-summary.md")
        XCTAssertEqual(h.files.text(at: summary),
                       "# Meeting summary\n\nTranscript: Meeting 2026-10-29 14-30-05.md\n\n- Decided to ship.\n")
    }

    func testASummaryThatCannotBeSavedSaysSo() {
        let h = makeHarness()
        say(h, "Hello.", from: .them, at: 0)
        h.archive.flush(snapshot: [])
        h.files.failure = TestFailure(message: "No permission")

        XCTAssertFalse(h.archive.saveSummary("- Decided to ship."))
        XCTAssertEqual(h.archive.lastError?.localizedDescription, "No permission")
    }

    // MARK: - Harness

    private final class Harness {
        let archive: TranscriptArchive
        let files: FakeTranscriptFiles
        var transcript: Transcript

        init(archive: TranscriptArchive, files: FakeTranscriptFiles, transcript: Transcript) {
            self.archive = archive
            self.files = files
            self.transcript = transcript
        }
    }

    private func makeHarness(files: FakeTranscriptFiles = FakeTranscriptFiles(),
                             limits: Transcript.Limits = Transcript.Limits()) -> Harness {
        var transcript = Transcript(limits: limits)
        transcript.collectsCommitted = true
        return Harness(archive: TranscriptArchive(folder: folder, started: started, files: files, format: format),
                       files: files, transcript: transcript)
    }

    /// A finished turn, handed to the archive the way the controller does it.
    private func say(_ h: Harness, _ text: String, from speaker: Speaker, at seconds: TimeInterval, utterance: Int = 0) {
        h.transcript.apply(TranscriptSegment(utterance: utterance, text: text, isFinal: true), from: speaker,
                           at: started + seconds)
        h.archive.append(h.transcript.collectCommitted())
    }
}
