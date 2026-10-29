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

    func testTheWelcomeScreenDoesNotPromiseOnDeviceTranscriptionUnconditionally() {
        XCTAssertFalse(WelcomeText.whereYourDataGoes.hasPrefix("Speech is transcribed on this Mac. When"))
    }
}
