import AppKit
import SwiftUI
import XCTest

/// Renders the overlay for a realistic session. The PNG is written to the
/// temporary directory so the layout can be looked at, not just asserted on.
@MainActor
final class OverlayRenderTests: XCTestCase {
    func testTheOverlayRendersALiveSession() async throws {
        let suite = "MeetingAssistantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults,
                                   secrets: InMemorySecretStore(values: ["anthropic_api_key": "sk-test"]),
                                   environment: [:], anthropicKeyFile: URL(fileURLWithPath: "/nonexistent"))
        let microphone = FakeMicrophone()
        microphone.authorized = false
        let transcribers = FakeTranscriberFactory()
        let answerer = FakeAnswerer()
        let controller = AssistantController(settings: settings, systemAudio: FakeSystemAudio(),
                                             microphone: microphone, makeTranscriber: transcribers.make,
                                             answerer: answerer)
        controller.start()
        await eventually { controller.listening == .listening }
        transcribers.latest(.them)?.emit("Thanks for joining. We looked at your proposal.", utterance: 0)
        transcribers.latest(.them)?.emit("What would the rollout timeline look like?", utterance: 1)
        controller.answerNow()
        answerer.streams[0].yield("- Pilot in two weeks with one team\n- Full rollout by end of quarter\n- Ask who owns the success metrics")
        answerer.streams[0].finish()
        await eventually { !controller.isAnswering }

        let png = try render(OverlayView(controller: controller, settings: settings, onHide: {}))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingAssistantOverlay.png")
        try png.write(to: url)
        print("Overlay render: \(url.path)")
        XCTAssertGreaterThan(png.count, 5_000)
    }

    private func render<Content: View>(_ content: Content) throws -> Data {
        let view = FirstClickHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
