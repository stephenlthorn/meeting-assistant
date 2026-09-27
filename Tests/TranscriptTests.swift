import XCTest

final class TranscriptTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testTurnsInterleaveInTheOrderTheyStart() {
        var transcript = Transcript()
        transcript.apply(partial(0, "Hi there"), from: .them, at: start)
        transcript.apply(partial(0, "Hello"), from: .you, at: start + 1)
        transcript.apply(final(0, "Hi there, how are you?"), from: .them, at: start + 2)

        XCTAssertEqual(transcript.text, "Them: Hi there, how are you?\nYou: Hello")
    }

    func testPartialResultsReplaceTheInProgressText() {
        var transcript = Transcript()
        transcript.apply(partial(0, "Hi"), from: .them, at: start)
        transcript.apply(partial(0, "Hi there"), from: .them, at: start + 1)

        XCTAssertEqual(transcript.text, "Them: Hi there")
    }

    func testALateFinalUpdatesItsOwnUtteranceNotANewerOne() {
        var transcript = Transcript()
        transcript.apply(partial(0, "first part"), from: .them, at: start)
        transcript.apply(partial(1, "second"), from: .them, at: start + 1)
        transcript.apply(final(0, "first part done."), from: .them, at: start + 2)

        XCTAssertEqual(transcript.text, "Them: first part done. second")
    }

    func testConsecutiveUtterancesFromOneSpeakerShareALine() {
        var transcript = Transcript()
        transcript.apply(final(0, "Hello."), from: .them, at: start)
        transcript.apply(final(1, "How are you?"), from: .them, at: start + 1)

        XCTAssertEqual(transcript.text, "Them: Hello. How are you?")
    }

    func testASpeakerChangeStartsANewLine() {
        var transcript = Transcript()
        transcript.apply(final(0, "Hi."), from: .them, at: start)
        transcript.apply(final(0, "Hey."), from: .you, at: start + 1)
        transcript.apply(final(1, "So, the plan."), from: .them, at: start + 2)

        XCTAssertEqual(transcript.text, "Them: Hi.\nYou: Hey.\nThem: So, the plan.")
    }

    func testBlankSegmentsDoNotCreateTurns() {
        var transcript = Transcript()
        transcript.apply(partial(0, "   "), from: .them, at: start)

        XCTAssertTrue(transcript.isEmpty)
        XCTAssertEqual(transcript.text, "")
    }

    func testAFinalThatClearsAnUtteranceRemovesItsText() {
        var transcript = Transcript()
        transcript.apply(partial(0, "uh"), from: .them, at: start)
        transcript.apply(final(0, ""), from: .them, at: start + 1)

        XCTAssertEqual(transcript.text, "")
    }

    func testMicrophoneEchoOfTheirSpeechIsHidden() {
        var transcript = Transcript()
        transcript.apply(final(0, "We should ship the beta next Tuesday."), from: .them, at: start)
        transcript.apply(final(0, "ship the beta next Tuesday"), from: .you, at: start + 1)

        XCTAssertEqual(transcript.text, "Them: We should ship the beta next Tuesday.")
    }

    func testAnOverlappingButDifferentReplyIsKept() {
        var transcript = Transcript()
        transcript.apply(final(0, "I think that's the right approach."), from: .them, at: start)
        transcript.apply(final(0, "Yes, I think that's right."), from: .you, at: start + 1)

        XCTAssertEqual(transcript.text, "Them: I think that's the right approach.\nYou: Yes, I think that's right.")
    }

    func testRepeatingTheirWordsLongAfterIsNotEcho() {
        var transcript = Transcript()
        transcript.apply(final(0, "We should ship the beta next Tuesday."), from: .them, at: start)
        transcript.apply(final(0, "ship the beta next Tuesday"), from: .you, at: start + 30)

        XCTAssertEqual(transcript.text, "Them: We should ship the beta next Tuesday.\nYou: ship the beta next Tuesday")
    }

    func testShortRepliesAreNeverTreatedAsEcho() {
        var transcript = Transcript()
        transcript.apply(final(0, "Next Tuesday works."), from: .them, at: start)
        transcript.apply(final(0, "Next Tuesday."), from: .you, at: start + 1)

        XCTAssertEqual(transcript.text, "Them: Next Tuesday works.\nYou: Next Tuesday.")
    }

    func testApplyReportsAFinishedTurn() {
        var transcript = Transcript()
        XCTAssertNil(transcript.apply(partial(0, "What's the"), from: .them, at: start))

        let finished = transcript.apply(final(0, "What's the plan?"), from: .them, at: start + 1)

        XCTAssertEqual(finished?.speaker, .them)
        XCTAssertEqual(finished?.text, "What's the plan?")
    }

    func testApplyDoesNotReportAHiddenEchoTurn() {
        var transcript = Transcript()
        transcript.apply(final(0, "Can you send the pricing sheet today?"), from: .them, at: start)

        let finished = transcript.apply(final(0, "send the pricing sheet today"), from: .you, at: start + 1)

        XCTAssertNil(finished)
    }

    func testTailKeepsWholeLinesFromTheEnd() {
        var transcript = Transcript()
        transcript.apply(final(0, "First line here."), from: .them, at: start)
        transcript.apply(final(0, "Second line."), from: .you, at: start + 1)
        transcript.apply(final(1, "Third line."), from: .them, at: start + 2)

        XCTAssertEqual(transcript.tail(maxCharacters: 35), "You: Second line.\nThem: Third line.")
    }

    func testTailCutsAnOverlongLineAtAWordAndKeepsItsSpeaker() {
        var transcript = Transcript()
        let words = (1...40).map { "word\($0)" }.joined(separator: " ")
        transcript.apply(final(0, words), from: .them, at: start)

        let tail = transcript.tail(maxCharacters: 40)

        XCTAssertTrue(tail.hasPrefix("Them: …"), tail)
        XCTAssertTrue(tail.hasSuffix("word40"), tail)
        XCTAssertLessThanOrEqual(tail.count, 40)
        XCTAssertFalse(tail.contains(" ord"), tail)
    }

    func testTailOfAShortTranscriptIsTheWholeText() {
        var transcript = Transcript()
        transcript.apply(final(0, "Hi."), from: .them, at: start)

        XCTAssertEqual(transcript.tail(maxCharacters: 500), "Them: Hi.")
    }

    func testUpdatesStayCheapAsAMeetingGrowsLong() {
        var transcript = Transcript()
        for index in 0..<3_000 {
            let speaker: Speaker = index.isMultiple(of: 2) ? .them : .you
            transcript.apply(final(index, "sentence number \(index) of a long meeting."), from: speaker,
                             at: start + TimeInterval(index))
        }

        let cpuSeconds = threadCPUSeconds {
            for step in 0..<2_000 {
                transcript.apply(partial(9_999, "live words \(step)"), from: .them, at: start + 5_000)
                _ = transcript.tail(maxCharacters: 1_500)
            }
        }

        XCTAssertLessThan(cpuSeconds, 0.5)
        XCTAssertTrue(transcript.tail(maxCharacters: 100).hasSuffix("live words 1999"))
    }

    private func partial(_ utterance: Int, _ text: String) -> TranscriptSegment {
        TranscriptSegment(utterance: utterance, text: text, isFinal: false)
    }

    private func final(_ utterance: Int, _ text: String) -> TranscriptSegment {
        TranscriptSegment(utterance: utterance, text: text, isFinal: true)
    }
}

func threadCPUSeconds(_ work: () -> Void) -> Double {
    var before = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &before)
    work()
    var after = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &after)
    return Double(after.tv_sec - before.tv_sec) + Double(after.tv_nsec - before.tv_nsec) / 1_000_000_000
}
