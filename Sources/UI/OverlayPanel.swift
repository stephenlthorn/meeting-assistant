import AppKit

/// A borderless, always-on-top, non-activating panel that hosts the overlay UI.
/// It never takes keyboard focus, so it does not disrupt the meeting app.
///
/// Note on "hidden from screen share": `sharingType = .none` excludes the window
/// from legacy capture APIs, but on macOS 15+ ScreenCaptureKit (what modern
/// meeting apps use) ignores it. If you are not screen sharing, the other side
/// never sees this window regardless.
final class OverlayPanel: NSPanel {
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
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
