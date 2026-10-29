import XCTest

/// Long meetings: the transcript keeps a bounded number of finished turns, and
/// one turn that never finishes cannot make every update re-render the rest.
final class TranscriptBoundsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let small = Transcript.Limits(maxTurns: 20, maxCharacters: 100_000, maxUncommitted: 8)

    func testAShortMeetingIsNotTrimmedAndCarriesNoMarker() {
        var transcript = Transcript(limits: small)
        for index in 0..<10 { transcript.apply(final(index, "line \(index)."), from: .them, at: start + TimeInterval(index)) }

        XCTAssertFalse(transcript.hasTrimmedText)
        XCTAssertFalse(transcript.text.contains(Transcript.trimmedMarker))
        XCTAssertTrue(transcript.text.hasPrefix("Them: line 0."))
    }

    func testOldTurnsAreTrimmedOncePastTheTurnLimit() {
        var transcript = Transcript(limits: small)

        for index in 0..<100 { say(&transcript, index) }

        XCTAssertLessThanOrEqual(transcript.retainedTurnCount, 20)
        XCTAssertGreaterThanOrEqual(transcript.retainedTurnCount, 10)
        XCTAssertTrue(transcript.hasTrimmedText)
        XCTAssertTrue(transcript.text.hasPrefix(Transcript.trimmedMarker + "\n"), transcript.text)
        XCTAssertFalse(transcript.text.contains("sentence 0 "))
        XCTAssertTrue(transcript.text.hasSuffix("sentence 99 of the review."))
    }

    func testTheCharacterLimitTrimsToo() {
        var transcript = Transcript(limits: .init(maxTurns: 10_000, maxCharacters: 600, maxUncommitted: 8))
        let long = String(repeating: "word ", count: 20)

        for index in 0..<40 { transcript.apply(final(index, long), from: .them, at: start + TimeInterval(index)) }

        XCTAssertTrue(transcript.hasTrimmedText)
        XCTAssertLessThanOrEqual(transcript.retainedCharacterCount, 600)
    }

    func testAfterTrimmingTheTailAndTheTextStillEndWithTheNewestLine() {
        var transcript = Transcript(limits: small)

        for index in 0..<100 { say(&transcript, index) }

        XCTAssertTrue(transcript.tail(maxCharacters: 300).hasSuffix("sentence 99 of the review."))
        XCTAssertFalse(transcript.tail(maxCharacters: 300).contains(Transcript.trimmedMarker))
        XCTAssertTrue(transcript.tail(maxCharacters: 300).hasPrefix("Them:") || transcript.tail(maxCharacters: 300).hasPrefix("You:"))
    }

    func testTheRetainedTextStartsOnAWholeLineWithItsSpeaker() {
        var transcript = Transcript(limits: small)

        for index in 0..<100 { say(&transcript, index) }

        let firstLine = transcript.text.components(separatedBy: "\n")[1]
        XCTAssertTrue(firstLine.hasPrefix("Them: ") || firstLine.hasPrefix("You: "), firstLine)
    }

    func testTheMarkerWordingCanBeChosenByTheCaller() {
        var transcript = Transcript(limits: small)
        for index in 0..<100 { say(&transcript, index) }

        XCTAssertTrue(transcript.text(trimmedNote: "[trimmed, see the saved file]").hasPrefix("[trimmed, see the saved file]\n"))
    }

    func testATurnStillBeingSpokenKeepsUpdatingInPlaceAcrossATrim() {
        var transcript = Transcript(limits: small)
        for index in 0..<100 { say(&transcript, index) }

        transcript.apply(partial(500, "and then"), from: .them, at: start + 1_000)
        transcript.apply(final(500, "and then we ship."), from: .them, at: start + 1_001)

        XCTAssertEqual(transcript.text.components(separatedBy: "and then").count - 1, 1)
        XCTAssertTrue(transcript.text.hasSuffix("and then we ship."))
    }

    func testAnUnfinishedTurnDoesNotHoldLaterTurnsOutOfTheCommittedText() {
        var transcript = Transcript(limits: .init(maxTurns: 1_000, maxCharacters: 100_000, maxUncommitted: 8))
        transcript.apply(partial(0, "so the thing is"), from: .them, at: start)
        var most = 0

        for index in 0..<50 {
            transcript.apply(final(index, "reply number \(index)."), from: .you, at: start + 1 + TimeInterval(index))
            most = max(most, transcript.uncommittedTurnCount)
        }

        XCTAssertLessThanOrEqual(most, 8)
        XCTAssertTrue(transcript.text.hasPrefix("Them: so the thing is\nYou: reply number 0."), transcript.text)
        XCTAssertTrue(transcript.text.hasSuffix("reply number 49."))
    }

    func testAnUpdateThatArrivesAfterItsTurnWasFrozenIsKeptNotLost() {
        var transcript = Transcript(limits: .init(maxTurns: 1_000, maxCharacters: 100_000, maxUncommitted: 8))
        transcript.apply(partial(0, "so the thing is"), from: .them, at: start)
        for index in 0..<20 { transcript.apply(final(index, "reply \(index)."), from: .you, at: start + 1 + TimeInterval(index)) }

        transcript.apply(final(0, "so the thing is, we ship."), from: .them, at: start + 100)

        XCTAssertTrue(transcript.text.hasSuffix("Them: so the thing is, we ship."), transcript.text)
    }

    func testTheHighestUtteranceIsRememberedAfterItsTurnWasTrimmed() {
        var transcript = Transcript(limits: small)
        for index in 0..<100 { transcript.apply(final(index, "sentence \(index) of the review."), from: .them, at: start + TimeInterval(index)) }
        transcript.apply(final(7, "a you line that is long enough."), from: .you, at: start + 200)

        XCTAssertEqual(transcript.highestUtterance(of: .them), 99)
        XCTAssertEqual(transcript.highestUtterance(of: .you), 7)
        XCTAssertNil(Transcript().highestUtterance(of: .them))
    }

    func testThrowingEverythingAwayStillLeavesATranscriptThatIsNotEmpty() {
        var transcript = Transcript(limits: .init(maxTurns: 2, maxCharacters: 10, maxUncommitted: 8))
        transcript.apply(final(0, "a very long first sentence indeed"), from: .them, at: start)
        transcript.apply(final(1, "another very long second sentence"), from: .you, at: start + 1)
        transcript.apply(final(2, "and a third very long sentence"), from: .them, at: start + 2)

        XCTAssertFalse(transcript.isEmpty)
        XCTAssertTrue(transcript.text.hasSuffix("and a third very long sentence"))
    }

    func testAThreeHourMeetingStaysBoundedAndFast() {
        var transcript = Transcript()
        var largestUncommitted = 0
        var largestRetained = 0
        var sizeAfterAnHour = 0
        // A Them sentence in the first minute whose final never arrives, which is
        // what a recognizer that died mid-sentence leaves behind.
        transcript.apply(partial(0, "so the thing is"), from: .them, at: start)

        let cpuSeconds = threadCPUSeconds {
            for turn in 1...2_700 {
                let speaker: Speaker = turn.isMultiple(of: 3) ? .you : .them
                let at = start + TimeInterval(turn * 4)
                // Different wording per side, so the microphone never looks like an echo of them.
                let sentence = speaker == .you
                    ? "turn \(turn): I will circulate the revised plan after lunch today."
                    : "turn \(turn): the quarterly numbers need another look before we commit to a date."
                transcript.apply(partial(turn, "turn \(turn): the quarterly"), from: speaker, at: at)
                transcript.apply(partial(turn, "turn \(turn): the quarterly numbers need another look"), from: speaker, at: at + 1)
                transcript.apply(final(turn, sentence), from: speaker, at: at + 2)
                _ = transcript.tail(maxCharacters: 1_500)
                largestUncommitted = max(largestUncommitted, transcript.uncommittedTurnCount)
                largestRetained = max(largestRetained, transcript.retainedTurnCount)
                if turn == 900 { sizeAfterAnHour = transcript.retainedCharacterCount }
            }
        }

        XCTAssertLessThanOrEqual(largestRetained, Transcript.Limits().maxTurns + Transcript.Limits().maxUncommitted)
        XCTAssertLessThanOrEqual(largestUncommitted, Transcript.Limits().maxUncommitted)
        XCTAssertLessThanOrEqual(transcript.retainedCharacterCount, Transcript.Limits().maxCharacters)
        XCTAssertLessThanOrEqual(transcript.retainedCharacterCount, sizeAfterAnHour * 2)
        XCTAssertTrue(transcript.text.hasPrefix(Transcript.trimmedMarker + "\n"))
        XCTAssertTrue(transcript.text.hasSuffix("turn 2700: I will circulate the revised plan after lunch today."), String(transcript.text.suffix(200)))
        XCTAssertLessThan(transcript.text.count, 60_000)
        XCTAssertLessThan(cpuSeconds, 5, "an update should not get slower as the meeting grows")
    }

    // MARK: - Helpers

    private func say(_ transcript: inout Transcript, _ index: Int) {
        let speaker: Speaker = index.isMultiple(of: 2) ? .them : .you
        transcript.apply(final(index, "sentence \(index) of the review."), from: speaker, at: start + TimeInterval(index * 20))
    }

    private func partial(_ utterance: Int, _ text: String) -> TranscriptSegment {
        TranscriptSegment(utterance: utterance, text: text, isFinal: false)
    }

    private func final(_ utterance: Int, _ text: String) -> TranscriptSegment {
        TranscriptSegment(utterance: utterance, text: text, isFinal: true)
    }
}
