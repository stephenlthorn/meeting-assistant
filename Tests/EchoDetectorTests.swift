import XCTest

final class EchoDetectorTests: XCTestCase {
    func testTheSameRunOfWordsIsEcho() {
        XCTAssertTrue(EchoDetector.isLikelyEcho("ship the beta next tuesday",
                                                of: "we should ship the beta next Tuesday"))
    }

    func testRecognitionDifferencesStillCountWhenMostWordsLineUp() {
        XCTAssertTrue(EchoDetector.isLikelyEcho("we should ship the better next tuesday afternoon",
                                                of: "We should ship the beta next Tuesday afternoon."))
    }

    func testSharedCommonWordsAreNotEcho() {
        XCTAssertFalse(EchoDetector.isLikelyEcho("yes I think that's right",
                                                 of: "I think that's the right approach"))
    }

    func testFewerThanFourWordsIsNeverEcho() {
        XCTAssertFalse(EchoDetector.isLikelyEcho("next Tuesday works", of: "next Tuesday works for us"))
    }

    func testPunctuationAndCaseAreIgnored() {
        XCTAssertTrue(EchoDetector.isLikelyEcho("Send the pricing sheet, today!",
                                                of: "can you send the pricing sheet today"))
    }
}
