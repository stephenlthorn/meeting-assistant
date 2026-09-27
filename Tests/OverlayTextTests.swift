import XCTest

final class OverlayTextTests: XCTestCase {
    func testTheTranscriptPlaceholderFollowsTheListeningState() {
        XCTAssertEqual(OverlayText.transcriptPlaceholder(for: .idle), "Not listening. Start from the menu bar icon.")
        XCTAssertEqual(OverlayText.transcriptPlaceholder(for: .starting), "Starting…")
        XCTAssertEqual(OverlayText.transcriptPlaceholder(for: .listening), "Listening for audio…")
    }

    func testTheAnswerAreaShowsTheAnswerOnceThereIsOne() {
        XCTAssertEqual(OverlayText.answer("- Ship in May", isAnswering: true, hasKey: true, shortcut: "⌘⇧Space"),
                       "- Ship in May")
    }

    func testTheAnswerAreaSaysItIsThinkingBeforeTheFirstWords() {
        XCTAssertEqual(OverlayText.answer("", isAnswering: true, hasKey: true, shortcut: "⌘⇧Space"), "Thinking…")
    }

    func testTheAnswerAreaSaysWhereToAddAMissingKey() {
        XCTAssertEqual(OverlayText.answer("", isAnswering: false, hasKey: false, shortcut: "⌘⇧Space"),
                       "Add your Anthropic API key: menu bar icon, then Settings…")
    }

    func testTheAnswerAreaNamesTheCurrentShortcut() {
        XCTAssertEqual(OverlayText.answer("", isAnswering: false, hasKey: true, shortcut: "⌃⌥Space"),
                       "Press ⌃⌥Space for help")
    }
}
