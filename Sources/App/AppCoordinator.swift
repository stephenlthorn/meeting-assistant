import Combine
import Foundation

/// The overlay window, as the coordinator drives it.
@MainActor
protocol OverlayPresenting: AnyObject {
    func show()
    func hide()
}

/// The welcome window. Its two buttons call back into the coordinator.
@MainActor
protocol WelcomePresenting: AnyObject {
    var onTrySample: (() -> Void)? { get set }
    var onAgree: (() -> Void)? { get set }
    func show()
    func close()
}

/// The meeting summary window.
@MainActor
protocol SummaryPresenting: AnyObject {
    func show()
}

@MainActor
protocol ClipboardWriting {
    func copy(_ text: String)
}

/// The panels that ask the user for a place on disk. A nil answer is a cancel.
@MainActor
protocol TranscriptDialogs {
    func chooseTranscriptFile(suggestedName: String, startingIn folder: URL) -> URL?
    func chooseTranscriptFolder(startingAt folder: URL) -> URL?
}

/// The app shell: what the menu, the shortcuts, the welcome screen and the
/// overlay window do, kept out of `MeetingAssistantApp` so tests can drive it.
/// Every system piece (windows, panels, the clipboard, the shortcut registry)
/// comes in from outside; the controller, settings and shortcut binder are
/// the real ones.
///
/// Nothing listens, answers or summarizes before the privacy terms are
/// accepted. The controller holds that line itself and asks for the welcome
/// screen through `onTermsNeeded`; accepting resumes what was asked for.
/// Terms from an older version (`AppSettings.termsVersion`) count as not accepted.
@MainActor
final class AppCoordinator {
    private let settings: AppSettings
    private let controller: AssistantController
    private let hotKeys: HotKeyBinder
    private let overlay: OverlayPresenting
    private let welcome: WelcomePresenting
    private let summary: SummaryPresenting
    private let dialogs: TranscriptDialogs
    private let clipboard: ClipboardWriting
    private var resumeAfterTerms: (() -> Void)?
    private var subscriptions: Set<AnyCancellable> = []

    init(settings: AppSettings,
         controller: AssistantController,
         hotKeys: HotKeyBinder,
         overlay: OverlayPresenting,
         welcome: WelcomePresenting,
         summary: SummaryPresenting,
         dialogs: TranscriptDialogs,
         clipboard: ClipboardWriting) {
        self.settings = settings
        self.controller = controller
        self.hotKeys = hotKeys
        self.overlay = overlay
        self.welcome = welcome
        self.summary = summary
        self.dialogs = dialogs
        self.clipboard = clipboard
        welcome.onAgree = { [weak self] in self?.acceptTerms() }
        welcome.onTrySample = { [weak self] in self?.trySample() }
    }

    /// What the menu shows now. Read it inside a view body to have the view follow it.
    var menu: MenuState {
        MenuState(controller: controller, settings: settings, hotKeyProblem: hotKeys.problem)
    }

    // MARK: - Launch and quit

    func start() {
        if settings.showsOverlay { overlay.show() }
        controller.onTermsNeeded = { [weak self] resume in self?.showWelcome(then: resume) }
        if !settings.hasAcceptedTerms { showWelcome() }
        settings.$answerHotKey.combineLatest(settings.$overlayHotKey)
            .sink { [weak self] answer, overlay in self?.bindHotKeys(answer: answer, overlay: overlay) }
            .store(in: &subscriptions)
    }

    /// Quitting in the middle of a call saves what was said since the last write.
    func willTerminate() {
        controller.saveBeforeQuit()
    }

    // MARK: - Terms

    /// Shows the welcome screen; `resume` runs once the terms are accepted. Opening
    /// it just to read leaves nothing waiting, so a Start the user gave up on
    /// does not begin listening from a later Agree.
    func showWelcome(then resume: (() -> Void)? = nil) {
        resumeAfterTerms = resume
        welcome.show()
    }

    /// Withdrawing stops the call first, so nothing is captured under terms the user took back.
    func withdrawTerms() {
        controller.stop()
        settings.withdrawTerms()
    }

    private func acceptTerms() {
        settings.acceptTerms()
        welcome.close()
        let resume = resumeAfterTerms
        resumeAfterTerms = nil
        resume?()
    }

    // MARK: - Overlay

    func toggleOverlay() {
        settings.showsOverlay.toggle()
        if settings.showsOverlay {
            overlay.show()
        } else {
            overlay.hide()
        }
    }

    func trySample() {
        welcome.close()
        if !settings.showsOverlay { toggleOverlay() }
        controller.startSample()
    }

    // MARK: - Menu actions

    func toggleListening() {
        controller.toggleListening()
    }

    func answerNow() {
        controller.answerNow()
    }

    func clearTranscript() {
        controller.clearTranscript()
    }

    func copyAnswer() {
        copy(controller.answer)
    }

    func copyTranscript() {
        copy(controller.transcriptText)
    }

    func copySummary() {
        copy(controller.summary)
    }

    /// Save Transcript...: asks where, then writes this call's transcript there.
    func saveTranscript() {
        guard let url = dialogs.chooseTranscriptFile(suggestedName: controller.suggestedTranscriptFileName,
                                                     startingIn: settings.transcriptFolder) else { return }
        controller.saveTranscript(to: url)
    }

    /// Summarize Meeting: the summary window comes up first, so the welcome
    /// screen that this may need to show ends up above it, not buried.
    func summarizeMeeting() {
        summary.show()
        controller.summarizeMeeting()
    }

    /// Settings > Transcripts > Choose Folder...
    func chooseTranscriptFolder() {
        guard let url = dialogs.chooseTranscriptFolder(startingAt: settings.transcriptFolder) else { return }
        settings.transcriptFolder = url
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        clipboard.copy(text)
    }

    // MARK: - Shortcuts

    private func bindHotKeys(answer: HotKeyCombo, overlay: HotKeyCombo) {
        hotKeys.bind(answer: answer, overlay: overlay,
                     onAnswer: { [weak self] in self?.answerNow() },
                     onOverlay: { [weak self] in self?.toggleOverlay() })
    }
}
