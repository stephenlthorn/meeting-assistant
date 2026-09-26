import AppKit
import SwiftUI

/// A borderless, always-on-top, non-activating panel that hosts the overlay UI.
/// It never takes keyboard focus, so it does not disrupt the meeting app, and
/// it reopens wherever it was last dragged.
///
/// Note on "hidden from screen share": `sharingType = .none` excludes the window
/// from legacy capture APIs, but on macOS 15+ ScreenCaptureKit (what modern
/// meeting apps use) ignores it. If you are not screen sharing, the other side
/// never sees this window regardless.
final class OverlayPanel: NSPanel {
    static let autosaveName = "MeetingAssistantOverlay"

    /// Whether a previously saved position was restored.
    private(set) var restoredSavedFrame = false

    init(contentView: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        sharingType = .none
        self.contentView = contentView
        setFrameAutosaveName(Self.autosaveName)
        restoredSavedFrame = setFrameUsingName(Self.autosaveName)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts SwiftUI in the overlay so its buttons work on the first click; the
/// panel never becomes key, so every click is a first click.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
