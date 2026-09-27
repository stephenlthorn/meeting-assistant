import XCTest

final class QuestionDetectorTests: XCTestCase {
    func testASentenceEndingInAQuestionMarkIsAQuestion() {
        XCTAssertTrue(QuestionDetector.looksLikeQuestion("We could start in May, would that work?"))
    }

    func testOnlyTheLastSentenceDecides() {
        XCTAssertTrue(QuestionDetector.looksLikeQuestion("That's great. What is the budget?"))
        XCTAssertFalse(QuestionDetector.looksLikeQuestion("What is the budget? We set it last week."))
    }

    func testAPunctuatedStatementStartingWithAQuestionWordIsNotAQuestion() {
        XCTAssertFalse(QuestionDetector.looksLikeQuestion("When we launched, sales doubled."))
    }

    func testUnpunctuatedTextStartingWithAQuestionWordIsAQuestion() {
        XCTAssertTrue(QuestionDetector.looksLikeQuestion("what is your timeline for the rollout"))
    }

    func testContractedQuestionWordsCount() {
        XCTAssertTrue(QuestionDetector.looksLikeQuestion("what's your timeline"))
        XCTAssertTrue(QuestionDetector.looksLikeQuestion("how's the migration going"))
        XCTAssertTrue(QuestionDetector.looksLikeQuestion("who's owning the launch"))
    }

    func testAuxiliaryVerbOpenersCount() {
        XCTAssertTrue(QuestionDetector.looksLikeQuestion("is it possible to start next week"))
        XCTAssertTrue(QuestionDetector.looksLikeQuestion("does that work for your team"))
        XCTAssertTrue(QuestionDetector.looksLikeQuestion("should we move the review"))
        XCTAssertTrue(QuestionDetector.looksLikeQuestion("have you tried restarting it"))
    }

    func testLeadingFillerWordsAreIgnored() {
        XCTAssertTrue(QuestionDetector.looksLikeQuestion("so what do you think"))
        XCTAssertTrue(QuestionDetector.looksLikeQuestion("Okay, and how would that scale"))
    }

    func testRequestsForExplanationCount() {
        XCTAssertTrue(QuestionDetector.looksLikeQuestion("walk me through the architecture"))
        XCTAssertTrue(QuestionDetector.looksLikeQuestion("tell me about your current setup"))
    }

    func testStatementsAreNotQuestions() {
        XCTAssertFalse(QuestionDetector.looksLikeQuestion("We shipped it yesterday"))
        XCTAssertFalse(QuestionDetector.looksLikeQuestion("I think that covers it."))
    }

    func testVeryShortFragmentsAreNotQuestions() {
        XCTAssertFalse(QuestionDetector.looksLikeQuestion("ok"))
        XCTAssertFalse(QuestionDetector.looksLikeQuestion(""))
    }
}
