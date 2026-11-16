import XCTest

/// Instant cards (N2) through the real controller: a trigger said by "Them"
/// shows its card at once, with no model, and a saved transcript logs it.
@MainActor
final class AssistantControllerCardsTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/Notes/Calls", isDirectory: true)

    // MARK: - Showing cards

    func testATriggerAsAPartialThenAsTheFinalTextShowsTheCardExactlyOnce() async {
        let h = makeHarness(cards: [card("Voicemail", "voicemail")])
        await startListening(h)

        h.transcribers.latest(.them)?.emit("most of it goes to voicemail", utterance: 0, isFinal: false)
        XCTAssertEqual(h.controller.cards.map(\.title), ["Voicemail"], "shown as soon as the words appear")

        h.transcribers.latest(.them)?.emit("Most of it goes to voicemail, honestly.", utterance: 0, isFinal: true)
        XCTAssertEqual(h.controller.cards.map(\.title), ["Voicemail"])
        XCTAssertEqual(h.controller.hiddenCardCount, 0)
    }

    func testANearMissWordShowsNothing() async {
        let h = makeHarness(cards: [card("Acme", "acme")])
        await startListening(h)

        h.transcribers.latest(.them)?.emit("We drove through Acmeville yesterday.", utterance: 0)

        XCTAssertEqual(h.controller.cards, [])
    }

    func testCardsNeverCallTheModel() async {
        let h = makeHarness(cards: [card("Voicemail", "voicemail")])
        await startListening(h)

        h.transcribers.latest(.them)?.emit("it goes to voicemail", utterance: 0)

        XCTAssertTrue(h.answerer.requests.isEmpty)
    }

    func testYourOwnLinesAreIgnoredUnlessYouTurnedThatOn() async {
        let h = makeHarness(cards: [card("Voicemail", "voicemail")])
        await startListening(h)

        h.transcribers.latest(.you)?.emit("so voicemail is the problem", utterance: 0)
        XCTAssertEqual(h.controller.cards, [])

        h.settings.cardsMatchYou = true
        h.transcribers.latest(.you)?.emit("so voicemail is the problem", utterance: 1)
        XCTAssertEqual(h.controller.cards.map(\.title), ["Voicemail"])
    }

    func testTheSameCardIsNotShownAgainWithinSixtySecondsOfBeingDismissed() async {
        let h = makeHarness(cards: [card("Voicemail", "voicemail")])
        await startListening(h)
        h.transcribers.latest(.them)?.emit("voicemail", utterance: 0)
        h.controller.dismissCard(id: h.controller.cards[0].id)
        XCTAssertEqual(h.controller.cards, [])

        h.clock.now.addTimeInterval(30)
        h.transcribers.latest(.them)?.emit("voicemail again", utterance: 1)
        XCTAssertEqual(h.controller.cards, [])

        h.clock.now.addTimeInterval(31)
        h.transcribers.latest(.them)?.emit("voicemail once more", utterance: 2)
        XCTAssertEqual(h.controller.cards.map(\.title), ["Voicemail"])
    }

    func testClearTranscriptClearsTheCards() async {
        let h = makeHarness(cards: [card("Voicemail", "voicemail")])
        await startListening(h)
        h.transcribers.latest(.them)?.emit("voicemail", utterance: 0)

        h.controller.clearTranscript()

        XCTAssertEqual(h.controller.cards, [])
    }

    func testAWordSaidBeforeAClearIsNotBroughtBackByTheUtteranceStillBeingSpoken() async {
        let h = makeHarness(cards: [card("Voicemail", "voicemail")])
        await startListening(h)
        h.transcribers.latest(.them)?.emit("voicemail", utterance: 0, isFinal: false)
        h.controller.clearTranscript()

        h.transcribers.latest(.them)?.emit("voicemail is the issue", utterance: 0, isFinal: true)

        XCTAssertEqual(h.controller.cards, [])
    }

    func testCardsAddedInSettingsMidCallStartMatchingAtOnce() async {
        let h = makeHarness(cards: [])
        await startListening(h)
        h.transcribers.latest(.them)?.emit("nothing yet", utterance: 0)

        h.settings.cards.add(card("Late", "rollout"))
        h.transcribers.latest(.them)?.emit("the rollout plan", utterance: 1)

        XCTAssertEqual(h.controller.cards.map(\.title), ["Late"])
    }

    func testDisabledCardsDoNotFire() async {
        let h = makeHarness(cards: [card("Off", "voicemail", enabled: false)])
        await startListening(h)

        h.transcribers.latest(.them)?.emit("voicemail", utterance: 0)

        XCTAssertEqual(h.controller.cards, [])
    }

    func testTheCardFolderIsReadAgainWhenListeningStarts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let h = makeHarness(cards: [])
        h.settings.cardsFolder = dir
        try "# Fresh\nTriggers: fresh\nBody".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        await startListening(h)
        h.transcribers.latest(.them)?.emit("something fresh", utterance: 0)

        XCTAssertEqual(h.controller.cards.map(\.title), ["Fresh"])
    }

    // MARK: - Saved transcript

    func testAShownCardIsLoggedInTheSavedTranscriptAtThatPointInTheCall() async {
        let h = makeHarness(cards: [card("Voicemail answer", "voicemail")], saving: true)
        await startListening(h)
        h.transcribers.latest(.them)?.emit("Hello there.", utterance: 0)
        h.transcribers.latest(.them)?.emit("it goes to voicemail", utterance: 1, isFinal: false)
        h.transcribers.latest(.them)?.emit("it goes to voicemail", utterance: 1, isFinal: true)
        h.transcribers.latest(.you)?.emit("Understood, thanks.", utterance: 0)

        h.controller.stop()

        let text = savedText(h)
        XCTAssertEqual(text.components(separatedBy: "> Card shown: Voicemail answer").count - 1, 1, text)
        let lines = text.split(separator: "\n").map(String.init)
        let card = lines.firstIndex(of: "> Card shown: Voicemail answer")
        let hello = lines.firstIndex { $0.hasSuffix("Them: Hello there.") }
        let thanks = lines.firstIndex { $0.hasSuffix("You: Understood, thanks.") }
        XCTAssertNotNil(card)
        XCTAssertTrue(hello! < card! && card! < thanks!, text)
    }

    func testNothingIsLoggedWhenSavingIsOff() async {
        let h = makeHarness(cards: [card("Voicemail", "voicemail")], saving: false)
        await startListening(h)

        h.transcribers.latest(.them)?.emit("voicemail", utterance: 0)
        h.controller.stop()

        XCTAssertEqual(h.files.writes, [])
    }

    // MARK: - Sample meeting

    func testTheSampleMeetingShowsItsOwnCardsWithNoSetup() async {
        let h = makeHarness(cards: [])

        h.controller.startSample()
        var shown: [String] = []
        while h.controller.listening == .sample {
            h.scheduler.fireAll()
            await h.settle()
            shown += h.controller.cards.map(\.title).filter { !shown.contains($0) }
        }

        XCTAssertEqual(Set(shown), Set(SampleMeeting.cards.map(\.title)))
        XCTAssertGreaterThanOrEqual(SampleMeeting.cards.count, 1)
        XCTAssertEqual(h.settings.cards.userCards, [], "sample cards are not saved into the user's cards")
        XCTAssertEqual(h.files.writes, [])
    }

    func testTheSampleCardsAreTriggeredByWhatThemSaysInTheScript() {
        let themWords = SampleMeeting.lines.filter { $0.speaker == .them }.map(\.text).joined(separator: " ")
        let matcher = CardMatcher(cards: SampleMeeting.cards)

        XCTAssertEqual(Set(matcher.matches(in: themWords).map(\.id)), Set(SampleMeeting.cards.map(\.id)))
    }

    func testTheSampleDoesNotUseTheUsersOwnCards() async {
        let h = makeHarness(cards: [card("Mine", "voicemail")])

        h.controller.startSample()
        for _ in 0..<SampleMeeting.lines.count {
            h.scheduler.fireAll()
            await h.settle()
        }

        XCTAssertFalse(h.controller.cards.map(\.title).contains("Mine"))
    }

    // MARK: - Harness

    private struct Harness {
        let controller: AssistantController
        let settings: AppSettings
        let systemAudio: FakeSystemAudio
        let transcribers: FakeTranscriberFactory
        let answerer: FakeAnswerer
        let clock: TestClock
        let scheduler: ManualScheduler
        let files: FakeTranscriptFiles

        func settle() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func card(_ title: String, _ triggers: String..., enabled: Bool = true) -> Card {
        Card(title: title, triggers: triggers, body: "Body of \(title)", isEnabled: enabled)
    }

    private func makeHarness(cards: [Card], saving: Bool = false) -> Harness {
        let settings = makeTestSettings(for: self)
        settings.saveTranscripts = saving
        settings.transcriptFolder = folder
        cards.forEach { settings.cards.add($0) }
        let systemAudio = FakeSystemAudio()
        let transcribers = FakeTranscriberFactory()
        let answerer = FakeAnswerer()
        let clock = TestClock()
        let scheduler = ManualScheduler()
        let files = FakeTranscriptFiles()
        let controller = AssistantController(settings: settings, systemAudio: systemAudio, microphone: FakeMicrophone(),
                                             makeTranscriber: transcribers.make, answerer: answerer,
                                             now: { clock.now }, schedule: scheduler.schedule,
                                             sampleWordDelay: 0, transcriptFiles: files)
        return Harness(controller: controller, settings: settings, systemAudio: systemAudio,
                       transcribers: transcribers, answerer: answerer, clock: clock, scheduler: scheduler, files: files)
    }

    private func startListening(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) async {
        h.controller.start()
        await eventually(file: file, line: line) {
            h.controller.listening == .listening && h.systemAudio.events.last != "start"
        }
    }

    private func savedText(_ h: Harness) -> String {
        h.files.files.first(where: { !$0.key.lastPathComponent.hasSuffix("-summary.md") })
            .flatMap { String(data: $0.value, encoding: .utf8) } ?? ""
    }
}
