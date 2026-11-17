import XCTest

final class VocabularyTests: XCTestCase {
    func testPhrasesAreTrimmedOnePerLineAndBlankLinesDropped() {
        let phrases = Vocabulary.normalize("  Kubernetes \n\n\t TiDB\n   \n")

        XCTAssertEqual(phrases, ["Kubernetes", "TiDB"])
    }

    func testRunsOfSpacesInsideAPhraseCollapse() {
        XCTAssertEqual(Vocabulary.normalize("Pied   Piper"), ["Pied Piper"])
    }

    func testDuplicatesIgnoringCaseKeepTheFirstSpelling() {
        let phrases = Vocabulary.normalize("TiDB\ntidb\nTIDB\nKubernetes\nkubernetes ")

        XCTAssertEqual(phrases, ["TiDB", "Kubernetes"])
    }

    func testTheListIsCappedAtOneHundredPhrases() {
        let text = (1...130).map { "term\($0)" }.joined(separator: "\n")

        let phrases = Vocabulary.normalize(text)

        XCTAssertEqual(phrases.count, 100)
        XCTAssertEqual(phrases.first, "term1")
        XCTAssertEqual(phrases.last, "term100")
    }

    func testTheCounterReportsEveryDistinctPhraseEvenPastTheCap() {
        let text = (1...130).map { "term\($0)" }.joined(separator: "\n") + "\nTERM1"

        let analysis = Vocabulary.analyze(text)

        XCTAssertEqual(analysis.distinctCount, 130)
        XCTAssertEqual(analysis.phrases.count, 100)
        XCTAssertEqual(analysis.ignoredCount, 30)
    }

    func testPhrasesLongerThanTwoWordsAreFlaggedButKept() {
        let analysis = Vocabulary.analyze("TiDB\nthe quick brown fox\nPied Piper")

        XCTAssertEqual(analysis.longPhrases, ["the quick brown fox"])
        XCTAssertEqual(analysis.phrases, ["TiDB", "the quick brown fox", "Pied Piper"])
    }

    func testUserTermsWinTheCapOverExtraTerms() {
        let user = (1...99).map { "user\($0)" }
        let extra = ["trigger one", "trigger two"]

        let effective = Vocabulary.effective(user: user, extra: extra)

        XCTAssertEqual(effective.count, 100)
        XCTAssertEqual(Array(effective.prefix(99)), user)
        XCTAssertEqual(effective.last, "trigger one")
    }

    func testAFullUserListLeavesNoRoomForExtraTerms() {
        let user = (1...100).map { "user\($0)" }

        XCTAssertEqual(Vocabulary.effective(user: user, extra: ["trigger"]), user)
    }

    func testAnExtraTermAlreadyInTheUserListIsNotRepeated() {
        let effective = Vocabulary.effective(user: ["TiDB"], extra: ["tidb", "Slate"])

        XCTAssertEqual(effective, ["TiDB", "Slate"])
    }

    func testExtraTermsAreNormalizedLikeUserTerms() {
        XCTAssertEqual(Vocabulary.effective(user: [], extra: ["  a  ", "A", ""]), ["a"])
    }
}
