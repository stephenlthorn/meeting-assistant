import AppKit
import SwiftUI
import XCTest

/// Renders the Settings window so the layout can be looked at; the PNG goes to
/// the temporary directory.
@MainActor
final class SettingsRenderTests: XCTestCase {
    func testTheSettingsWindowRendersWithTheMeetingAudioChoice() throws {
        let settings = makeTestSettings(for: self)
        settings.captureAppBundleID = "us.zoom.xos"
        let view = SettingsView(settings: settings, hotKeys: HotKeyBinder(), showWelcome: {}, withdrawTerms: {})

        let png = try render(view, size: NSSize(width: 480, height: 720))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingAssistantSettings.png")
        try png.write(to: url)
        print("Settings render: \(url.path)")
        XCTAssertGreaterThan(png.count, 5_000)
    }

    private func render<Content: View>(_ content: Content, size: NSSize) throws -> Data {
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
