import XCTest

final class WelcomeTextTests: XCTestCase {
    func testTheWelcomeScreenListsEveryPlaceCallDataCanGo() {
        let text = WelcomeText.whereYourDataGoes

        XCTAssertTrue(text.contains("Anthropic"))
        XCTAssertTrue(text.contains("Deepgram"))
        XCTAssertTrue(text.contains("Apple's speech servers"))
    }

    func testTheWelcomeScreenSaysAppleServersNeedTheirOwnOptIn() {
        let text = WelcomeText.whereYourDataGoes

        XCTAssertTrue(text.contains("only if you separately turn that on"), text)
    }

    func testTheWelcomeScreenSaysSummarizeMeetingSendsTheWholeTranscript() {
        let text = WelcomeText.whereYourDataGoes

        XCTAssertTrue(text.contains("Summarize Meeting"), text)
        XCTAssertTrue(text.contains("whole transcript"), text)
        XCTAssertTrue(text.contains("Claude"), text)
    }

    func testTheWelcomeScreenKeepsTheRecentExcerptsWordingForAnswers() {
        XCTAssertTrue(WelcomeText.whereYourDataGoes.contains("the last few minutes of transcript text"))
    }

    func testTheWelcomeScreenSaysSavedTranscriptsStayOnThisMacUnlessTheFolderSyncs() {
        let text = WelcomeText.whereYourDataGoes

        XCTAssertTrue(text.contains("If you turn on saving, transcripts are written as files on this Mac"), text)
        XCTAssertTrue(text.contains("stay on this Mac unless you choose a folder that syncs to iCloud"), text)
        XCTAssertFalse(text.contains("only on this Mac"), "that promise was false for a folder iCloud syncs")
    }

    func testTheWelcomeScreenStillSaysNothingGoesToTheDeveloper() {
        XCTAssertTrue(WelcomeText.whereYourDataGoes.hasSuffix("Nothing is sent to the developer."))
    }

    func testTheWelcomeScreenDoesNotPromiseOnDeviceTranscriptionUnconditionally() {
        XCTAssertFalse(WelcomeText.whereYourDataGoes.hasPrefix("Speech is transcribed on this Mac. When"))
    }
}
