import XCTest

/// What the transcript hands to the saver: finished turns in transcript order,
/// before a trim can drop them, and the turns still in progress.
final class TranscriptCommitQueueTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testNothingIsQueuedUnlessAskedFor() {
        var transcript = Transcript()
        transcript.apply(final(0, "Hello there."), from: .them, at: start)

        XCTAssertEqual(transcript.collectCommitted(), [])
    }

    func testFinishedTurnsAreHandedOverOnceInTranscriptOrder() {
        var transcript = Transcript()
        transcript.collectsCommitted = true
        transcript.apply(final(0, "Hello there."), from: .them, at: start)
        transcript.apply(final(0, "Hi, good to see you."), from: .you, at: start + 5)

        XCTAssertEqual(transcript.collectCommitted().map(\.text), ["Hello there.", "Hi, good to see you."])
        XCTAssertEqual(transcript.collectCommitted(), [])
    }

    func testATurnIsHandedOverWhenItsPlaceIsFinalNotWhenItEnds() {
        var transcript = Transcript()
        transcript.collectsCommitted = true
        transcript.apply(partial(0, "so the thing"), from: .them, at: start)
        transcript.apply(final(0, "Sure, go ahead."), from: .you, at: start + 1)
        XCTAssertEqual(transcript.collectCommitted(), [], "the earlier turn is still open")

        transcript.apply(final(0, "so the thing is late."), from: .them, at: start + 2)

        XCTAssertEqual(transcript.collectCommitted().map(\.text), ["so the thing is late.", "Sure, go ahead."])
    }

    func testHiddenEchoTurnsAreNotHandedOver() {
        var transcript = Transcript()
        transcript.collectsCommitted = true
        transcript.apply(final(0, "We should ship the beta next Tuesday."), from: .them, at: start)
        transcript.apply(final(0, "ship the beta next Tuesday"), from: .you, at: start + 1)

        XCTAssertEqual(transcript.collectCommitted().map(\.text), ["We should ship the beta next Tuesday."])
    }

    func testTurnsCollectedBeforeATrimAreNotLostByIt() {
        var transcript = Transcript(limits: .init(maxTurns: 10, maxCharacters: 100_000, maxUncommitted: 8))
        transcript.collectsCommitted = true
        var collected: [String] = []

        for index in 0..<60 {
            transcript.apply(final(index, "sentence \(index) of the review."), from: .them, at: start + TimeInterval(index))
            collected += transcript.collectCommitted().map(\.text)
        }

        XCTAssertEqual(collected, (0..<60).map { "sentence \($0) of the review." })
        XCTAssertLessThanOrEqual(transcript.retainedTurnCount, 10)
    }

    func testTurnsInProgressAreListedSeparately() {
        var transcript = Transcript()
        transcript.apply(final(0, "Hello there."), from: .them, at: start)
        transcript.apply(partial(1, "and one more"), from: .them, at: start + 1)

        XCTAssertEqual(transcript.uncommittedTurns.map(\.text), ["and one more"])
        XCTAssertEqual(transcript.visibleTurns.map(\.text), ["Hello there.", "and one more"])
    }

    func testATurnRemembersWhenItStartedNotWhenItEnded() {
        var transcript = Transcript()
        transcript.apply(partial(0, "so"), from: .them, at: start)
        let finished = transcript.apply(final(0, "so that is that."), from: .them, at: start + 9)

        XCTAssertEqual(finished?.startedAt, start)
        XCTAssertEqual(finished?.updatedAt, start + 9)
    }

    private func partial(_ utterance: Int, _ text: String) -> TranscriptSegment {
        TranscriptSegment(utterance: utterance, text: text, isFinal: false)
    }

    private func final(_ utterance: Int, _ text: String) -> TranscriptSegment {
        TranscriptSegment(utterance: utterance, text: text, isFinal: true)
    }
}
