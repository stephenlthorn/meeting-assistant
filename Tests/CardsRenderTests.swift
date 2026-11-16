import AppKit
import SwiftUI
import XCTest

/// The overlay with a full stack of cards, written to the temporary directory so
/// the layout can be looked at: the answer must stay readable beside them.
@MainActor
final class CardsRenderTests: XCTestCase {
    func testTheOverlayRendersAFullStackOfCardsBesideTheAnswer() async throws {
        let settings = makeTestSettings(for: self)
        for word in ["alpha", "beta", "gamma", "delta"] {
            settings.cards.add(Card(title: "Card \(word)", triggers: [word],
                                    body: "First point about \(word)\n- second **bold** point\n- third point\n- fourth point\n- fifth"))
        }
        let transcribers = FakeTranscriberFactory()
        let answerer = FakeAnswerer()
        let controller = AssistantController(settings: settings, systemAudio: FakeSystemAudio(),
                                             microphone: FakeMicrophone(), makeTranscriber: transcribers.make,
                                             answerer: answerer)
        controller.start()
        await eventually { controller.listening == .listening }
        for (index, word) in ["alpha", "beta", "gamma", "delta"].enumerated() {
            transcribers.latest(.them)?.emit("they said \(word)", utterance: index)
        }
        controller.answerNow()
        answerer.streams[0].yield("- Pilot in two weeks\n- Full rollout by quarter end")
        answerer.streams[0].finish()
        await eventually { !controller.isAnswering }
        XCTAssertEqual(controller.cards.count, 3)
        XCTAssertEqual(controller.hiddenCardCount, 1)

        let view = NSHostingView(rootView: OverlayView(controller: controller, settings: settings, onHide: {}))
        view.frame = NSRect(x: 0, y: 0, width: 380, height: 420)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingAssistantCards.png")
        try png.write(to: url)
        print("Cards render: \(url.path)")
        XCTAssertGreaterThan(png.count, 5_000)
    }
}
