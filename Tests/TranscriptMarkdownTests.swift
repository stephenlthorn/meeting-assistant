import XCTest

final class TranscriptMarkdownTests: XCTestCase {
    /// 2026-10-29 14:30:05 UTC.
    private let started = Date(timeIntervalSince1970: 1_793_284_205)
    private let utc = TranscriptMarkdown(timeZone: TimeZone(identifier: "UTC")!)

    func testTheFileIsNamedByStartTimeWithNoCharacterAFileSystemDislikes() {
        XCTAssertEqual(utc.fileStem(started: started), "Meeting 2026-10-29 14-30-05")
    }

    func testTheNameFollowsTheLocalTimeZone() {
        let tokyo = TranscriptMarkdown(timeZone: TimeZone(identifier: "Asia/Tokyo")!)

        XCTAssertEqual(tokyo.fileStem(started: started), "Meeting 2026-10-29 23-30-05")
    }

    func testTheHeaderGivesTheDateAndTime() {
        XCTAssertEqual(utc.header(started: started), "# Meeting transcript\n\nStarted: 2026-10-29 14:30:05\n\n")
    }

    func testEachTurnIsATimestampedLineWithItsSpeaker() {
        var transcript = Transcript()
        transcript.apply(TranscriptSegment(utterance: 0, text: "Hi, how are you?", isFinal: true), from: .them,
                         at: started + 12)
        transcript.apply(TranscriptSegment(utterance: 0, text: "Good, thanks.", isFinal: true), from: .you,
                         at: started + 3_700)

        let lines = transcript.visibleTurns.map(utc.line(for:))

        XCTAssertEqual(lines, ["- [14:30:17] Them: Hi, how are you?\n", "- [15:31:45] You: Good, thanks.\n"])
    }

    func testALineBreakInsideATurnDoesNotSplitItsLine() {
        var transcript = Transcript()
        transcript.apply(TranscriptSegment(utterance: 0, text: "first\nsecond", isFinal: true), from: .them, at: started)

        XCTAssertEqual(utc.line(for: transcript.visibleTurns[0]), "- [14:30:05] Them: first second\n")
    }

    func testADocumentIsTheHeaderTheTrimNoteAndTheLines() {
        var transcript = Transcript()
        transcript.apply(TranscriptSegment(utterance: 0, text: "Hello.", isFinal: true), from: .them, at: started)

        let document = utc.document(started: started, turns: transcript.visibleTurns, trimmedNote: "[earlier lines trimmed]")

        XCTAssertEqual(document, """
            # Meeting transcript

            Started: 2026-10-29 14:30:05

            [earlier lines trimmed]

            - [14:30:05] Them: Hello.

            """)
    }

    func testADocumentWithoutATrimNoteGoesStraightToTheLines() {
        var transcript = Transcript()
        transcript.apply(TranscriptSegment(utterance: 0, text: "Hello.", isFinal: true), from: .them, at: started)

        let document = utc.document(started: started, turns: transcript.visibleTurns, trimmedNote: nil)

        XCTAssertTrue(document.hasSuffix("Started: 2026-10-29 14:30:05\n\n- [14:30:05] Them: Hello.\n"), document)
    }

    func testASummaryDocumentNamesItsTranscript() {
        let document = utc.summaryDocument(summary: "  - Decided to ship.\n", transcriptName: "Meeting 2026-10-29 14-30-05.md")

        XCTAssertEqual(document, "# Meeting summary\n\nTranscript: Meeting 2026-10-29 14-30-05.md\n\n- Decided to ship.\n")
    }
}
