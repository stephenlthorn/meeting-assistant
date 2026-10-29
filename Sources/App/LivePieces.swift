import AppKit
import SwiftUI

// The AppKit side of `AppCoordinator`: real windows, panels and the clipboard.
// They hold no decisions, which is why they are the only part of the shell
// without tests. Each window is built the first time it is shown.

/// The floating overlay. It reopens wherever it was last dragged, and starts at
/// the top right of the main screen the first time.
@MainActor
final class OverlayWindow: OverlayPresenting {
    private let makeContent: () -> NSView
    private var panel: OverlayPanel?

    init(content: @escaping () -> NSView) {
        makeContent = content
    }

    func show() {
        let panel = panel ?? makePanel()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentView: makeContent())
        if !panel.restoredSavedFrame { positionTopRight(panel) }
        self.panel = panel
        return panel
    }

    private func positionTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 20
        let frame = panel.frame
        let x = screen.visibleFrame.maxX - frame.width - margin
        let y = screen.visibleFrame.maxY - frame.height - margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class WelcomeWindow: WelcomePresenting {
    var onTrySample: (() -> Void)?
    var onAgree: (() -> Void)?
    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let welcome = WelcomeView(onTrySample: { [weak self] in self?.onTrySample?() },
                                  onAgree: { [weak self] in self?.onAgree?() })
        let hosting = NSHostingController(rootView: welcome)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Meeting Assistant"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        return window
    }
}

@MainActor
final class SummaryWindow: SummaryPresenting {
    private let controller: AssistantController
    private var window: NSWindow?

    init(controller: AssistantController) {
        self.controller = controller
    }

    func show() {
        let window = window ?? makeWindow()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SummaryView(controller: controller)))
        window.title = "Meeting Summary"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 460, height: 380))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        return window
    }
}

struct SystemClipboard: ClipboardWriting {
    func copy(_ text: String) {
        Clipboard.copy(text)
    }
}

struct AppKitTranscriptDialogs: TranscriptDialogs {
    func chooseTranscriptFile(suggestedName: String, startingIn folder: URL) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = folder
        panel.canCreateDirectories = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func chooseTranscriptFolder(startingAt folder: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Meeting Assistant saves transcripts."
        panel.directoryURL = folder
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
