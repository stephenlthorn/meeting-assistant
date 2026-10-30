import XCTest

/// The app shell (terms, overlay, shortcuts, menu actions) through the real
/// coordinator, controller, settings and shortcut binder, with fakes only for
/// the windows, panels, clipboard, shortcut registry and the capture system.
@MainActor
final class AppCoordinatorTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/Notes/Calls", isDirectory: true)

    // MARK: - Terms gating

    func testNothingListensBeforeTheTermsAreAccepted() async {
        let h = makeHarness(termsAccepted: false)
        h.coordinator.start()

        h.coordinator.toggleListening()
        await settle()

        XCTAssertEqual(h.controller.listening, .idle)
        XCTAssertTrue(h.transcribers.made.isEmpty)
        XCTAssertTrue(h.systemAudio.events.isEmpty)
        XCTAssertEqual(h.microphone.starts, 0)
        XCTAssertEqual(h.welcome.shows, 2, "once at launch, once because Start needs the terms")
    }

    func testAcceptingTheTermsCarriesOnWithListening() async {
        let h = makeHarness(termsAccepted: false)
        h.coordinator.start()
        h.coordinator.toggleListening()

        h.welcome.agree()

        await eventually { h.controller.listening == .listening }
        XCTAssertTrue(h.settings.hasAcceptedTerms)
        XCTAssertEqual(h.welcome.closes, 1)
        XCTAssertEqual(h.transcribers.made.count, 2)
    }

    func testAnAnswerIsNotRequestedBeforeTheTermsAndIsAskedForOnceTheyAreAccepted() async {
        let h = makeHarness(termsAccepted: false)
        h.coordinator.start()

        h.coordinator.answerNow()

        XCTAssertEqual(h.controller.answer, "", "the answer step did not even run")
        XCTAssertTrue(h.answerer.requests.isEmpty)
        let shownAtStart = h.welcome.shows

        h.welcome.agree()

        XCTAssertEqual(h.controller.answer, "No transcript yet. Start listening first.", "the answer carried on after Agree")
        XCTAssertEqual(h.welcome.shows, shownAtStart)
    }

    func testTermsFromAnOlderVersionAreAskedForAgain() async {
        let h = makeHarness(acceptedTermsVersion: AppSettings.termsVersion - 1)

        h.coordinator.start()

        XCTAssertFalse(h.settings.hasAcceptedTerms)
        XCTAssertEqual(h.welcome.shows, 1, "the welcome screen comes up at launch")
        h.coordinator.toggleListening()
        await settle()
        XCTAssertEqual(h.controller.listening, .idle)
        XCTAssertTrue(h.transcribers.made.isEmpty)

        h.welcome.agree()

        XCTAssertTrue(h.settings.hasAcceptedTerms)
        await eventually { h.controller.listening == .listening }
    }

    func testCurrentTermsAreNotAskedForAtLaunch() {
        let h = makeHarness()

        h.coordinator.start()

        XCTAssertEqual(h.welcome.shows, 0)
    }

    func testWithdrawingTheTermsStopsTheCallAndAsksAgainAtTheNextStart() async {
        let h = makeHarness()
        h.coordinator.start()
        await startListening(h)

        h.coordinator.withdrawTerms()

        XCTAssertEqual(h.controller.listening, .idle)
        XCTAssertFalse(h.settings.hasAcceptedTerms)
        let made = h.transcribers.made.count
        h.coordinator.toggleListening()
        await settle()
        XCTAssertEqual(h.transcribers.made.count, made)
        XCTAssertEqual(h.welcome.shows, 1)
    }

    func testReviewingTheWelcomeScreenLeavesNoStartWaitingBehindIt() async {
        let h = makeHarness(termsAccepted: false)
        h.coordinator.start()
        h.coordinator.toggleListening()

        h.coordinator.showWelcome()
        h.welcome.agree()
        await settle()

        XCTAssertEqual(h.controller.listening, .idle, "listening never starts from a screen the user only opened to read")
        XCTAssertTrue(h.transcribers.made.isEmpty)
    }

    func testTheSampleMeetingNeedsNoTermsAndLeavesThemUnaccepted() {
        let h = makeHarness(termsAccepted: false)
        h.coordinator.start()

        h.welcome.trySample()

        XCTAssertEqual(h.controller.listening, .sample)
        XCTAssertFalse(h.settings.hasAcceptedTerms)
        XCTAssertEqual(h.welcome.closes, 1)
        XCTAssertTrue(h.transcribers.made.isEmpty)
    }

    func testTheSampleMeetingBroughtUpFromTheMenuShowsAHiddenOverlay() {
        let h = makeHarness(showsOverlay: false)
        h.coordinator.start()
        XCTAssertFalse(h.overlay.isVisible)

        h.coordinator.trySample()

        XCTAssertTrue(h.overlay.isVisible)
        XCTAssertTrue(h.settings.showsOverlay)
        XCTAssertEqual(h.controller.listening, .sample)
    }

    // MARK: - Overlay

    func testTheOverlayIsShownAtLaunchWhenItWasLeftOn() {
        let h = makeHarness(showsOverlay: true)

        h.coordinator.start()

        XCTAssertTrue(h.overlay.isVisible)
    }

    func testTheOverlayStaysHiddenAtLaunchWhenItWasHidden() {
        let h = makeHarness(showsOverlay: false)

        h.coordinator.start()

        XCTAssertEqual(h.overlay.shows, 0)
        XCTAssertFalse(h.overlay.isVisible)
    }

    func testTogglingTheOverlayHidesAndShowsItAndRemembersTheChoice() {
        let h = makeHarness()
        h.coordinator.start()

        h.coordinator.toggleOverlay()
        XCTAssertFalse(h.overlay.isVisible)
        XCTAssertFalse(h.settings.showsOverlay)

        h.coordinator.toggleOverlay()
        XCTAssertTrue(h.overlay.isVisible)
        XCTAssertTrue(h.settings.showsOverlay)
    }

    func testTheOverlayShortcutTogglesTheOverlay() {
        let h = makeHarness()
        h.coordinator.start()

        h.registry.press(HotKeyCombo.overlayChoices[0])

        XCTAssertFalse(h.overlay.isVisible)
        h.registry.press(HotKeyCombo.overlayChoices[0])
        XCTAssertTrue(h.overlay.isVisible)
    }

    // MARK: - Shortcuts

    func testStartingBindsTheShortcutsFromSettings() {
        let h = makeHarness()

        h.coordinator.start()

        XCTAssertEqual(Set(h.registry.live), [HotKeyCombo.answerChoices[0], HotKeyCombo.overlayChoices[0]])
    }

    func testChangingAShortcutInSettingsRebindsIt() {
        let h = makeHarness()
        h.coordinator.start()

        h.settings.answerHotKey = HotKeyCombo.answerChoices[1]

        XCTAssertEqual(Set(h.registry.live), [HotKeyCombo.answerChoices[1], HotKeyCombo.overlayChoices[0]])
        h.registry.press(HotKeyCombo.answerChoices[1])
        XCTAssertEqual(h.controller.answer, "No transcript yet. Start listening first.", "the new shortcut asks for an answer")

        h.settings.overlayHotKey = HotKeyCombo.overlayChoices[1]

        XCTAssertEqual(Set(h.registry.live), [HotKeyCombo.answerChoices[1], HotKeyCombo.overlayChoices[1]])
        h.registry.press(HotKeyCombo.overlayChoices[1])
        XCTAssertFalse(h.overlay.isVisible, "the new overlay shortcut toggles the overlay")
    }

    func testTheAnswerShortcutAsksForAnAnswerFromTheTranscript() async {
        let h = makeHarness()
        h.coordinator.start()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What would the rollout look like?", utterance: 0)

        h.registry.press(HotKeyCombo.answerChoices[0])

        XCTAssertEqual(h.answerer.requests.count, 1)
        XCTAssertTrue(h.answerer.requests[0].user.contains("What would the rollout look like?"))
    }

    func testAShortcutAnotherAppOwnsIsReportedInTheMenu() {
        let h = makeHarness()
        h.registry.takenElsewhere = [HotKeyCombo.answerChoices[0]]

        h.coordinator.start()

        XCTAssertEqual(h.coordinator.menu.notes, ["⌃⌥Space is already in use. Pick another shortcut in Settings."])
    }

    // MARK: - What the menu shows

    func testBeforeAnythingHappensOnlyTheActionsThatCanWorkAreEnabled() {
        let h = makeHarness()
        h.coordinator.start()

        let menu = h.coordinator.menu

        XCTAssertEqual(menu.statusLine, "Idle")
        XCTAssertEqual(menu.listeningTitle, "Start Listening")
        XCTAssertEqual(menu.answerNowTitle, "Answer Now (⌃⌥Space)")
        XCTAssertEqual(menu.overlayTitle, "Hide Overlay (⌃⌥H)")
        XCTAssertTrue(menu.canTrySample)
        XCTAssertFalse(menu.canCopyAnswer)
        XCTAssertFalse(menu.canCopyTranscript)
        XCTAssertFalse(menu.canSaveTranscript)
        XCTAssertFalse(menu.canSummarize)
        XCTAssertFalse(menu.canCopySummary)
        XCTAssertFalse(menu.canClearTranscript)
    }

    func testOnceTheCallHasATranscriptItsActionsTurnOn() async {
        let h = makeHarness()
        h.coordinator.start()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What would the rollout look like?", utterance: 0)

        let menu = h.coordinator.menu

        XCTAssertEqual(menu.listeningTitle, "Stop Listening")
        XCTAssertFalse(menu.canTrySample, "a sample cannot start over a real call")
        XCTAssertTrue(menu.canCopyTranscript)
        XCTAssertTrue(menu.canSaveTranscript)
        XCTAssertTrue(menu.canSummarize)
        XCTAssertTrue(menu.canClearTranscript)
        XCTAssertFalse(menu.canCopyAnswer, "there is no answer yet")
        XCTAssertFalse(menu.canCopySummary, "there is no summary yet")
    }

    func testTheTranscriptActionsStayOnAfterStopSoACallCanBeSavedAndSummarized() async {
        let h = makeHarness()
        h.coordinator.start()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What would the rollout look like?", utterance: 0)

        h.coordinator.toggleListening()

        let menu = h.coordinator.menu
        XCTAssertEqual(menu.listeningTitle, "Start Listening")
        XCTAssertTrue(menu.canTrySample)
        XCTAssertTrue(menu.canCopyTranscript)
        XCTAssertTrue(menu.canSaveTranscript)
        XCTAssertTrue(menu.canSummarize)
    }

    func testAnAnswerCanBeCopiedOnceItExists() async {
        let h = makeHarness()
        h.coordinator.start()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What would the rollout look like?", utterance: 0)

        h.coordinator.answerNow()
        h.answerer.streams[0].yield("Pilot in two weeks")
        await eventually { h.controller.answer == "Pilot in two weeks" }

        XCTAssertTrue(h.coordinator.menu.canCopyAnswer)
    }

    func testSummarizeIsOffWhileASummaryIsBeingWrittenAndCopyIsOnceThereIsOne() async {
        let h = makeHarness()
        h.coordinator.start()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What would the rollout look like?", utterance: 0)

        h.coordinator.summarizeMeeting()
        h.answerer.streams[0].yield("Decisions: pilot first.")
        await eventually { h.controller.summary == "Decisions: pilot first." }

        XCTAssertFalse(h.coordinator.menu.canSummarize, "one summary at a time")
        XCTAssertTrue(h.coordinator.menu.canCopySummary)

        h.answerer.streams[0].finish()
        await eventually { !h.controller.isSummarizing }
        XCTAssertTrue(h.coordinator.menu.canSummarize)
    }

    func testTheSampleMeetingCanBeStoppedFromTheMenu() {
        let h = makeHarness()
        h.coordinator.start()

        h.coordinator.trySample()

        XCTAssertEqual(h.coordinator.menu.listeningTitle, "Stop Sample Meeting")
        XCTAssertFalse(h.coordinator.menu.canTrySample)
    }

    func testAnswerNowAndTheOverlayTitleFollowTheShortcutsAndTheOverlay() {
        let h = makeHarness()
        h.coordinator.start()
        h.settings.answerHotKey = HotKeyCombo.answerChoices[2]
        h.settings.overlayHotKey = HotKeyCombo.overlayChoices[3]

        h.coordinator.toggleOverlay()

        XCTAssertEqual(h.coordinator.menu.answerNowTitle, "Answer Now (⌘⇧Space)")
        XCTAssertEqual(h.coordinator.menu.overlayTitle, "Show Overlay (⌘⇧O)")
    }

    func testAnswerNowStaysEnabledSoItCanExplainWhatIsMissing() {
        let h = makeHarness()
        h.coordinator.start()

        h.coordinator.answerNow()

        XCTAssertEqual(h.controller.answer, "No transcript yet. Start listening first.")
    }

    func testTheMenuPointsAtAMissingOrUnreadableApiKey() {
        let missing = makeHarness(secrets: InMemorySecretStore())
        let present = makeHarness()

        XCTAssertEqual(missing.coordinator.menu.notes, ["Add your API key in Settings"])
        XCTAssertEqual(present.coordinator.menu.notes, [])
    }

    func testTheMenuSaysWhenMacOSWillNotLetTheAppReadTheSavedKey() async {
        let locked = makeHarness(secrets: LockedSecretStore())
        locked.coordinator.start()

        await startListening(locked)

        XCTAssertEqual(locked.coordinator.menu.notes, ["Allow Keychain access to your API key in Settings"])
    }

    func testTheMenuOffersTheSettingsPaneThatFixesAProblem() async {
        let h = makeHarness()
        h.systemAudio.startError = SystemAudioError.permissionDenied
        h.coordinator.start()

        h.coordinator.toggleListening()
        await eventually { h.controller.listening == .listening && !h.controller.problems.isEmpty }

        XCTAssertEqual(h.coordinator.menu.privacyFixes, [.screenRecording])
    }

    // MARK: - The status line

    func testTheStatusLineNamesTheSpeechBackendAndTheClaudeModel() async {
        let h = makeHarness()
        h.coordinator.start()

        await startListening(h)

        XCTAssertEqual(h.coordinator.menu.statusLine, "Listening (on-device) - Haiku 4.5")
    }

    func testTheStatusLineFollowsABackendThatSendsAudioElsewhereAndAModelChange() async {
        let h = makeHarness()
        h.transcribers.backendName = "Deepgram"
        h.coordinator.start()
        await startListening(h)

        h.settings.model = "claude-sonnet-5"

        XCTAssertEqual(h.coordinator.menu.statusLine, "Listening (Deepgram) - Sonnet 5")
    }

    func testTheStatusLineStopsNamingTheModelOnceTheCallEnds() async {
        let h = makeHarness()
        h.coordinator.start()
        await startListening(h)

        h.coordinator.toggleListening()

        XCTAssertEqual(h.coordinator.menu.statusLine, "Stopped")
    }

    // MARK: - Menu actions

    func testToggleListeningStartsAndStops() async {
        let h = makeHarness()
        h.coordinator.start()

        await startListening(h)
        XCTAssertEqual(h.controller.listening, .listening)

        h.coordinator.toggleListening()
        XCTAssertEqual(h.controller.listening, .idle)
    }

    func testCopyAnswerPutsTheAnswerOnTheClipboard() async {
        let h = makeHarness()
        h.coordinator.start()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What would the rollout look like?", utterance: 0)
        h.coordinator.answerNow()
        h.answerer.streams[0].yield("Pilot in two weeks")
        await eventually { h.controller.answer == "Pilot in two weeks" }

        h.coordinator.copyAnswer()

        XCTAssertEqual(h.clipboard.copies, ["Pilot in two weeks"])
    }

    func testCopyTranscriptPutsTheTranscriptOnTheClipboard() async {
        let h = makeHarness()
        h.coordinator.start()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What would the rollout look like?", utterance: 0)

        h.coordinator.copyTranscript()

        XCTAssertEqual(h.clipboard.copies, [h.controller.transcriptText])
        XCTAssertTrue(h.clipboard.copies[0].contains("What would the rollout look like?"))
    }

    func testCopySummaryPutsTheSummaryOnTheClipboard() async {
        let h = makeHarness()
        h.coordinator.start()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What would the rollout look like?", utterance: 0)
        h.coordinator.summarizeMeeting()
        h.answerer.streams[0].yield("Decisions: pilot first.")
        await eventually { h.controller.summary == "Decisions: pilot first." }

        h.coordinator.copySummary()

        XCTAssertEqual(h.clipboard.copies, ["Decisions: pilot first."])
    }

    func testCopyingNothingLeavesTheClipboardAlone() {
        let h = makeHarness()
        h.coordinator.start()

        h.coordinator.copyAnswer()
        h.coordinator.copyTranscript()
        h.coordinator.copySummary()

        XCTAssertEqual(h.clipboard.copies, [])
    }

    func testClearTranscriptEmptiesTheTranscriptAndTurnsItsActionsOff() async {
        let h = makeHarness()
        h.coordinator.start()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What would the rollout look like?", utterance: 0)

        h.coordinator.clearTranscript()

        XCTAssertEqual(h.controller.transcriptDisplay, "")
        XCTAssertFalse(h.coordinator.menu.canClearTranscript)
        XCTAssertFalse(h.coordinator.menu.canSaveTranscript)
    }

    func testSaveTranscriptWritesTheCallWhereTheUserChose() async {
        let h = makeHarness()
        h.coordinator.start()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What would the rollout look like?", utterance: 0)
        let chosen = folder.appendingPathComponent("Rollout call.md")
        h.dialogs.fileChoice = chosen

        h.coordinator.saveTranscript()

        XCTAssertEqual(h.dialogs.fileRequests.map { $0.suggestedName }, [h.controller.suggestedTranscriptFileName])
        XCTAssertEqual(h.dialogs.fileRequests.map { $0.folder }, [h.settings.transcriptFolder])
        XCTAssertTrue(h.files.text(at: chosen)?.contains("What would the rollout look like?") ?? false)
    }

    func testCancellingTheSavePanelWritesNothing() async {
        let h = makeHarness()
        h.coordinator.start()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What would the rollout look like?", utterance: 0)
        h.dialogs.fileChoice = nil

        h.coordinator.saveTranscript()

        XCTAssertEqual(h.dialogs.fileRequests.count, 1)
        XCTAssertEqual(h.files.writes, [])
    }

    func testShowTranscriptsFolderRevealsTheFolderSavedTranscriptsGoTo() {
        let h = makeHarness()
        h.coordinator.start()

        h.coordinator.showTranscriptsFolder()

        XCTAssertEqual(h.dialogs.revealedFolders, [folder])
    }

    func testShowTranscriptsFolderRevealsTheDefaultFolderWhenNoneWasChosen() {
        let h = makeHarness()
        h.settings.transcriptFolder = AppSettings.defaultTranscriptFolder

        h.coordinator.showTranscriptsFolder()

        XCTAssertEqual(h.dialogs.revealedFolders.map(\.path), [AppSettings.defaultTranscriptFolder.path])
    }

    func testShowTranscriptsFolderFollowsANewFolderChoice() {
        let h = makeHarness()
        let chosen = URL(fileURLWithPath: "/Volumes/Work/Calls", isDirectory: true)
        h.dialogs.folderChoice = chosen
        h.coordinator.chooseTranscriptFolder()

        h.coordinator.showTranscriptsFolder()

        XCTAssertEqual(h.dialogs.revealedFolders, [chosen])
    }

    func testShowTranscriptsFolderNeedsNoTermsBecauseNothingLeavesTheMac() {
        let h = makeHarness(termsAccepted: false)
        h.coordinator.start()
        let shown = h.welcome.shows

        h.coordinator.showTranscriptsFolder()

        XCTAssertEqual(h.dialogs.revealedFolders, [folder])
        XCTAssertEqual(h.welcome.shows, shown, "revealing a folder does not ask for the terms")
    }

    func testSummarizeMeetingAsksClaudeAndShowsTheSummaryWindow() async {
        let h = makeHarness()
        h.coordinator.start()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("What would the rollout look like?", utterance: 0)

        h.coordinator.summarizeMeeting()

        XCTAssertEqual(h.answerer.requests.count, 1)
        XCTAssertEqual(h.summaryWindow.shows, 1)
        XCTAssertTrue(h.controller.isSummarizing)
    }

    func testSummarizeBeforeTheTermsSendsNothingAndLeavesTheWelcomeScreenOnTop() async {
        let h = makeHarness(termsAccepted: false)
        h.coordinator.start()
        h.windowLog.clear()

        h.coordinator.summarizeMeeting()

        XCTAssertTrue(h.answerer.requests.isEmpty)
        XCTAssertEqual(h.windowLog.events, ["summary", "welcome"], "the welcome screen is shown last, so it is not buried")
    }

    func testChoosingTheTranscriptFolderSavesTheChoiceInSettings() {
        let h = makeHarness()
        let chosen = URL(fileURLWithPath: "/Users/me/Calls", isDirectory: true)
        h.dialogs.folderChoice = chosen

        h.coordinator.chooseTranscriptFolder()

        XCTAssertEqual(h.settings.transcriptFolder, chosen)
        XCTAssertEqual(h.dialogs.folderRequests, [folder], "the panel opens on the folder in use")
    }

    func testCancellingTheFolderPanelKeepsTheFolder() {
        let h = makeHarness()
        h.dialogs.folderChoice = nil

        h.coordinator.chooseTranscriptFolder()

        XCTAssertEqual(h.settings.transcriptFolder, folder)
    }

    func testQuittingMidCallSavesWhatWasSaid() async {
        let h = makeHarness()
        h.settings.saveTranscripts = true
        h.coordinator.start()
        await startListening(h)
        h.transcribers.latest(.them)?.emit("Said just before the quit.", utterance: 0)
        XCTAssertEqual(h.files.writes, [])

        h.coordinator.willTerminate()

        XCTAssertTrue(h.files.files.values.contains { String(data: $0, encoding: .utf8)?.contains("Said just before the quit.") ?? false })
    }

    // MARK: - Harness

    private struct Harness {
        let coordinator: AppCoordinator
        let controller: AssistantController
        let settings: AppSettings
        let overlay: FakeOverlay
        let welcome: FakeWelcome
        let summaryWindow: FakeSummaryWindow
        let windowLog: WindowLog
        let clipboard: FakeClipboard
        let dialogs: FakeDialogs
        let registry: FakeHotKeyRegistry
        let systemAudio: FakeSystemAudio
        let microphone: FakeMicrophone
        let transcribers: FakeTranscriberFactory
        let answerer: FakeAnswerer
        let files: FakeTranscriptFiles
    }

    private func makeHarness(termsAccepted: Bool = true,
                             acceptedTermsVersion: Int? = nil,
                             showsOverlay: Bool = true,
                             secrets: SecretStore = InMemorySecretStore(values: ["anthropic_api_key": "sk-test"])) -> Harness {
        let settings = makeSettings(acceptedTermsVersion: acceptedTermsVersion ?? (termsAccepted ? AppSettings.termsVersion : 0),
                                    secrets: secrets)
        settings.showsOverlay = showsOverlay
        settings.transcriptFolder = folder
        let systemAudio = FakeSystemAudio()
        let microphone = FakeMicrophone()
        let transcribers = FakeTranscriberFactory()
        let answerer = FakeAnswerer()
        let clock = TestClock()
        let scheduler = ManualScheduler()
        let files = FakeTranscriptFiles()
        let controller = AssistantController(settings: settings, systemAudio: systemAudio, microphone: microphone,
                                             makeTranscriber: transcribers.make, answerer: answerer,
                                             now: { clock.now }, schedule: scheduler.schedule,
                                             sampleWordDelay: 0, transcriptFiles: files)
        let registry = FakeHotKeyRegistry()
        let windowLog = WindowLog()
        let overlay = FakeOverlay()
        let welcome = FakeWelcome(log: windowLog)
        let summaryWindow = FakeSummaryWindow(log: windowLog)
        let clipboard = FakeClipboard()
        let dialogs = FakeDialogs()
        let coordinator = AppCoordinator(settings: settings, controller: controller,
                                         hotKeys: HotKeyBinder(register: registry.register),
                                         overlay: overlay, welcome: welcome, summary: summaryWindow,
                                         dialogs: dialogs, clipboard: clipboard)
        return Harness(coordinator: coordinator, controller: controller, settings: settings, overlay: overlay,
                       welcome: welcome, summaryWindow: summaryWindow, windowLog: windowLog, clipboard: clipboard,
                       dialogs: dialogs, registry: registry, systemAudio: systemAudio, microphone: microphone,
                       transcribers: transcribers, answerer: answerer, files: files)
    }

    /// Settings over throwaway defaults that already hold `acceptedTermsVersion`,
    /// as if an earlier release had been agreed to.
    private func makeSettings(acceptedTermsVersion: Int, secrets: SecretStore) -> AppSettings {
        let suite = "MeetingAssistantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(acceptedTermsVersion, forKey: "acceptedTermsVersion")
        return AppSettings(defaults: defaults, secrets: secrets, environment: [:],
                           anthropicKeyFile: URL(fileURLWithPath: "/nonexistent/anthropic_key"))
    }

    private func startListening(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) async {
        if h.controller.listening == .idle { h.coordinator.toggleListening() }
        await eventually(file: file, line: line) {
            h.controller.listening == .listening && h.systemAudio.events.last != "start"
        }
    }
}
