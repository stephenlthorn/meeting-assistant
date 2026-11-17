import XCTest

/// Where two v0.4 features meet: instant cards and Summarize Meeting, and the answer
/// language and the follow-up draft.
final class SummaryCardLinesTests: XCTestCase {
    /// A saved transcript logs each card shown, but the card is the user's own note,
    /// not something said on the call, so it never goes out with the summary request.
    func testCardLinesFromTheSavedFileAreNotSentWithTheSummary() {
        let saved = """
        - [10:00:01] Them: Most calls go to voicemail.
        > Card shown: Missed calls
        - [10:00:05] You: Got it.
        """

        let input = SummaryInput(transcript: saved, isPartial: false)

        XCTAssertFalse(input.transcript.contains("Card shown"))
        XCTAssertFalse(input.transcript.contains("Missed calls"))
        XCTAssertTrue(input.transcript.contains("Them: Most calls go to voicemail."))
        XCTAssertTrue(input.transcript.contains("You: Got it."))
    }

    func testATranscriptLineThatMerelyMentionsCardsIsKept() {
        let saved = "- [10:00:01] Them: Did you see the card shown at the booth?"

        let input = SummaryInput(transcript: saved, isPartial: false)

        XCTAssertEqual(input.transcript, saved)
    }
}

final class FollowUpLanguageTests: XCTestCase {
    func testTheFollowUpIsWrittenInTheChosenAnswerLanguage() {
        let system = FollowUpPrompt.system(profile: .sales, extraInstructions: "", languageSentence: "Answer in German.")

        XCTAssertTrue(system.contains("Answer in German."))
    }

    func testWithoutAnAnswerLanguageTheFollowUpPromptIsUnchanged() {
        XCTAssertEqual(FollowUpPrompt.system(profile: .sales, extraInstructions: "", languageSentence: nil),
                       FollowUpPrompt.system(profile: .sales, extraInstructions: ""))
    }
}
