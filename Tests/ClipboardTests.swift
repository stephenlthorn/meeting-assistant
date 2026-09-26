import AppKit
import XCTest

final class ClipboardTests: XCTestCase {
    func testCopyingPutsTheTextOnThePasteboard() {
        let pasteboard = privatePasteboard()

        Clipboard.copy("Them: Hello.", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "Them: Hello.")
    }

    func testCopyingNothingLeavesThePasteboardAlone() {
        let pasteboard = privatePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)

        Clipboard.copy("", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "before")
    }

    private func privatePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MeetingAssistantTests.\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }
}
