import AppKit
import SwiftUI
import XCTest

/// Renders the overlay for a realistic session. The PNG is written to the
/// temporary directory so the layout can be looked at, not just asserted on.
@MainActor
final class OverlayRenderTests: XCTestCase {
    func testTheOverlayRendersALiveSession() async throws {
        let settings = makeTestSettings(for: self)
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

    func testTheOverlayRendersTheSampleMeeting() async throws {
        let settings = makeTestSettings(for: self)
        let answerer = FakeAnswerer()
        let scheduler = ManualScheduler()
        let controller = AssistantController(settings: settings, systemAudio: FakeSystemAudio(),
                                             microphone: FakeMicrophone(), makeTranscriber: FakeTranscriberFactory().make,
                                             answerer: answerer, schedule: scheduler.schedule, sampleWordDelay: 0)
        controller.startSample()
        while answerer.requests.isEmpty {
            scheduler.fireAll()
            await eventually { !scheduler.delays.isEmpty || !answerer.requests.isEmpty }
        }
        answerer.streams[0].yield(SampleMeeting.sampleAnswers[0])
        answerer.streams[0].finish()
        await eventually { !controller.isAnswering }

        let png = try render(OverlayView(controller: controller, settings: settings, onHide: {}))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingAssistantSample.png")
        try png.write(to: url)
        print("Sample render: \(url.path)")
        XCTAssertGreaterThan(png.count, 5_000)
    }

    func testTheWelcomeScreenRenders() throws {
        let png = try render(WelcomeView(onTrySample: {}, onAgree: {}), size: NSSize(width: 540, height: 470))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingAssistantWelcome.png")
        try png.write(to: url)
        print("Welcome render: \(url.path)")
        XCTAssertGreaterThan(png.count, 5_000)
    }

    private func render<Content: View>(_ content: Content, size: NSSize = NSSize(width: 380, height: 420)) throws -> Data {
        let view = FirstClickHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
