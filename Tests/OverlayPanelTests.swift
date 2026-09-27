import AppKit
import SwiftUI
import XCTest

@MainActor
final class OverlayPanelTests: XCTestCase {
    func testThePanelRemembersWhereItWasMoved() {
        let panel = OverlayPanel(contentView: NSView())

        XCTAssertEqual(panel.frameAutosaveName, "MeetingAssistantOverlay")
    }

    func testThePanelNeverTakesKeyboardFocusFromTheMeeting() {
        let panel = OverlayPanel(contentView: NSView())

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }

    func testOverlayButtonsRespondToTheFirstClick() {
        let view = FirstClickHostingView(rootView: Text("Copy"))

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }
}
