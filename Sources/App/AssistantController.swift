import AppKit
import AVFoundation
import Combine
import Foundation
import Observation

/// Which side of the conversation a transcript line came from.
enum Speaker: String {
    case you = "You"
    case them = "Them"
}

enum ListeningState: Equatable {
    case idle, starting, listening, sample
}

/// Orchestrates the pipeline: system audio (them) and the microphone (you)
/// feed two transcribers whose segments merge into one speaker-labeled
/// transcript; on demand (or auto-answer) the recent transcript goes to Claude.
///
/// Everything here runs on the main actor except audio, which capture threads
/// hand to the current transcribers through lock-protected slots. Each Start
/// and Stop begins a new session, and callbacks from older sessions are
/// ignored, except that segments from the session that was just stopped are
/// still accepted for `drainWindow`, so the last sentence of a call is not lost.
/// Starting and stopping system audio is chained, so a Start never overlaps the
/// previous Stop.
///
/// Capture that dies mid-call is brought back: system audio (a display going to
/// sleep, a monitor unplugged) is restarted with backoff while its transcriber
/// keeps running, and again at once when the Mac wakes or the displays change;
/// if that fails for good the side is marked failed, so the status never claims
/// to be listening to something that is not there. The microphone retries
/// itself and reports only when that fails or recovers.
///
/// A side can also break without saying so. A transcriber that gives up says so
/// (`onFatal`) and its side is marked failed at once. A watchdog per side, checked
/// every `watchdogInterval` while its session lasts, restarts capture that stopped
/// delivering audio and a transcriber that hears speech and writes nothing; if the
/// side is still broken afterwards the user is told once. The same per-side meters
/// feed `levels` for the overlay's indicator.
///
/// System audio is limited to the app chosen in Settings when that app is running
/// (`AppSettings.captureAppBundleID`, read at each start and restart); otherwise
/// every app is heard, and a notice says so.
///
/// Listening and answering wait until the privacy terms are accepted;
/// `onTermsNeeded` receives a closure that carries on once they are. The
/// sample meeting needs no terms, since it records nothing.
@MainActor
@Observable
final class AssistantController {
    static let displayCharacters = 1_500
    static let promptCharacters = 4_000
    static let autoAnswerInterval: TimeInterval = 6
    static let defaultDrainWindow: TimeInterval = 2
    /// Waits before each attempt to restart system audio; when they run out, it gives up.
    static let systemAudioRetryDelays: [TimeInterval] = [1, 2, 4, 8, 15, 15]
    /// How often each side's audio is checked for silent breakage.
    static let watchdogInterval: TimeInterval = 5
    private static let maxProblems = 3

    private(set) var listening: ListeningState = .idle
    private(set) var status = "Idle"
    private(set) var problems: [Problem] = []
    private(set) var notice: String?
    private(set) var transcriptDisplay = ""
    private(set) var answer = ""
    private(set) var isAnswering = false
    /// Per-side loudness for the overlay's level indicator.
    let levels = CaptureLevels()

    var isListening: Bool { listening != .idle }
    var transcriptText: String { transcript.text }

    /// Asked to show the privacy terms; call the closure once they are accepted.
    @ObservationIgnored var onTermsNeeded: ((@escaping () -> Void) -> Void)?

    private enum SideState { case off, pending, up, reconnecting, failed }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let systemAudio: SystemAudioCapturing
    @ObservationIgnored private let microphone: MicrophoneCapturing
    @ObservationIgnored private let makeTranscriber: @MainActor (Speaker) -> LiveTranscriber
    @ObservationIgnored private let answerer: AnswerStreaming
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    @ObservationIgnored private let sampleWordDelay: TimeInterval
    @ObservationIgnored private let drainWindow: TimeInterval
    @ObservationIgnored private let watchdogSchedule: (TimeInterval, @escaping () -> Void) -> Void

    @ObservationIgnored private let themSlot = TranscriberSlot()
    @ObservationIgnored private let youSlot = TranscriberSlot()
    @ObservationIgnored private var themTranscriber: LiveTranscriber?
    @ObservationIgnored private var youTranscriber: LiveTranscriber?
    @ObservationIgnored private var themSide = SideState.off { didSet { sideChanged(.them, to: themSide) } }
    @ObservationIgnored private var youSide = SideState.off { didSet { sideChanged(.you, to: youSide) } }
    @ObservationIgnored private let themMeter: AudioMeter
    @ObservationIgnored private let youMeter: AudioMeter
    @ObservationIgnored private var speakerNotices: [Speaker: String] = [:]
    @ObservationIgnored private var captureNotice: String?
    @ObservationIgnored private var backendName = ""
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var drainingSession: Int?
    @ObservationIgnored private var lifecycle: Task<Void, Never>?
    @ObservationIgnored private var themRecovery = 0
    @ObservationIgnored private var themAttempts = 0
    @ObservationIgnored private var themCanRevive = false
    @ObservationIgnored private var captureProblems: [Speaker: Problem] = [:]
    @ObservationIgnored private var watchdogs: [Speaker: SideWatchdog] = [:]
    /// Sides whose replacement transcriber is waiting for its permission answer.
    /// Nothing is judged for them: the transcriber has not been started yet.
    @ObservationIgnored private var awaitingSpeechPermission: Set<Speaker> = []
    @ObservationIgnored private var lastWatchdogTick = Date.distantPast
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    @ObservationIgnored private var transcript = Transcript()
    @ObservationIgnored private var clearedThrough: [Speaker: Int] = [:]
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    @ObservationIgnored private var answerRequest = 0
    @ObservationIgnored private var lastAutoAnswer = Date.distantPast
    @ObservationIgnored private var sampleAnswersShown = 0

    init(settings: AppSettings,
         systemAudio: SystemAudioCapturing,
         microphone: MicrophoneCapturing,
         makeTranscriber: @escaping @MainActor (Speaker) -> LiveTranscriber,
         answerer: AnswerStreaming,
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = runAfter,
         sampleWordDelay: TimeInterval = 0.04,
         drainWindow: TimeInterval = AssistantController.defaultDrainWindow,
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         notifications: NotificationCenter = .default,
         meterClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         watchdogSchedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = runAfter) {
        self.settings = settings
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.makeTranscriber = makeTranscriber
        self.answerer = answerer
        self.now = now
        self.schedule = schedule
        self.sampleWordDelay = sampleWordDelay
        self.drainWindow = drainWindow
        self.watchdogSchedule = watchdogSchedule
        let levels = self.levels
        themMeter = AudioMeter(clock: meterClock, onLevel: { level in
            deliverOnMain { levels.update(.them, rms: level) }
        })
        youMeter = AudioMeter(clock: meterClock, onLevel: { level in
            deliverOnMain { levels.update(.you, rms: level) }
        })
        systemAudio.onBuffer = { [themSlot, themMeter] buffer in
            themMeter.observe(buffer)
            themSlot.append(buffer)
        }
        microphone.onBuffer = { [youSlot, youMeter] buffer in
            youMeter.observe(buffer)
            youSlot.append(buffer)
        }
        observeEnvironment(workspace: workspaceNotifications, screens: notifications)
    }

    deinit {
        observers.forEach { $0.center.removeObserver($0.token) }
    }

    static func live(settings: AppSettings) -> AssistantController {
        AssistantController(settings: settings,
                            systemAudio: SystemAudioCapture(),
                            microphone: MicCapture(),
                            makeTranscriber: { _ in TranscriberFactory.make(settings: settings) },
                            answerer: AnthropicClient())
    }

    // MARK: - Listening

    func toggleListening() {
        isListening ? stop() : start()
    }

    func start() {
        guard listening == .idle else { return }
        guard settings.hasAcceptedTerms else {
            onTermsNeeded?({ [weak self] in self?.start() })
            return
        }
        session += 1
        drainingSession = nil
        let current = session
        listening = .starting
        status = "Starting…"
        problems = []
        captureProblems = [:]
        themCanRevive = false
        themRecovery += 1
        awaitingSpeechPermission = []
        clearNotices()
        resetTranscriptAndAnswer()
        beginPrivacySession()
        watchCapture(session: current)
        lastWatchdogTick = now()
        scheduleWatchdog(session: current)

        let them = makeTranscriber(.them)
        let you = makeTranscriber(.you)
        wire(them, as: .them, session: current)
        wire(you, as: .you, session: current)
        themTranscriber = them
        youTranscriber = you
        backendName = them.backendName
        themSide = .pending
        youSide = .pending

        them.requestAuthorization { [weak self] granted in
            deliverOnMain { self?.speechAuthorizationResolved(granted, session: current) }
        }
    }

    func stop() {
        guard listening != .idle else { return }
        let stopped = session
        let hadTranscribers = themTranscriber != nil || youTranscriber != nil
        session += 1
        tearDown()
        listening = .idle
        status = "Stopped"
        clearNotices()
        if hadTranscribers { drain(stopped) }
    }

    /// The transcribers were just told to stop, and a recognizer that was
    /// mid-sentence reports the rest of it a moment later. Segments from that
    /// session are accepted until the window closes or a new session starts.
    private func drain(_ stopped: Int) {
        drainingSession = stopped
        schedule(drainWindow) { [weak self] in
            deliverOnMain { if self?.drainingSession == stopped { self?.drainingSession = nil } }
        }
    }

    private func speechAuthorizationResolved(_ granted: Bool, session current: Int) {
        guard session == current else { return }
        guard granted else {
            report(Problem(message: "Speech Recognition permission is off. Allow Meeting Assistant in System Settings.",
                           fix: .speechRecognition))
            themSide = .failed
            youSide = .failed
            resolveStartup()
            return
        }
        startThemSide(session: current)
        startYouSide(session: current)
    }

    private func startThemSide(session current: Int) {
        guard let them = themTranscriber else { return }
        them.start()
        themSlot.set(them)
        let previous = lifecycle
        lifecycle = Task { [weak self, systemAudio] in
            await previous?.value
            do {
                try await systemAudio.start(application: self?.settings.captureAppBundleID)
                guard let self, self.session == current else {
                    await systemAudio.stop()
                    return
                }
                // Their transcriber may have given up while this was starting; the
                // stop it queued is next in the chain, so the side stays failed.
                if self.themSide == .pending { self.themSide = .up }
                self.resolveStartup()
            } catch {
                guard let self, self.session == current else { return }
                self.themSlot.set(nil)
                them.stop()
                self.themSide = .failed
                self.report(Self.problem(forSystemAudioError: error))
                self.resolveStartup()
            }
        }
    }

    private func startYouSide(session current: Int) {
        microphone.requestAuthorization { [weak self] granted in
            deliverOnMain { self?.microphoneAuthorizationResolved(granted, session: current) }
        }
    }

    private func microphoneAuthorizationResolved(_ granted: Bool, session current: Int) {
        guard session == current, let you = youTranscriber else { return }
        guard granted else {
            youSide = .failed
            report(Problem(message: "Microphone access is off, so only their side is transcribed.", fix: .microphone))
            resolveStartup()
            return
        }
        you.start()
        youSlot.set(you)
        do {
            try microphone.start()
            youSide = .up
        } catch {
            youSlot.set(nil)
            you.stop()
            youSide = .failed
            report(Problem(message: "Couldn't start the microphone: \(error.localizedDescription)"))
        }
        resolveStartup()
    }

    private func resolveStartup() {
        switch (themSide, youSide) {
        case (.failed, .failed):
            session += 1
            tearDown()
            listening = .idle
            status = "Not listening"
        case (.up, _), (_, .up), (.reconnecting, _), (_, .reconnecting):
            listening = .listening
            status = listeningStatus()
        default:
            break
        }
    }

    /// A side is metered and watched only while its capture is up. A side that is
    /// reconnecting keeps its watchdog, so what was already restarted is remembered.
    private func sideChanged(_ speaker: Speaker, to state: SideState) {
        levels.setActive(speaker, state == .up)
        switch state {
        case .up: armWatchdog(for: speaker)
        case .reconnecting: break
        case .off, .pending, .failed: watchdogs[speaker] = nil
        }
        if speaker == .them, state == .failed, captureNotice != nil {
            captureNotice = nil
            refreshNotice()
        }
    }

    private func listeningStatus() -> String {
        let scope: String? = switch (themSide, youSide) {
        case (.up, .failed): "their side only"
        case (.failed, .up): "your side only"
        case (.reconnecting, .up): "reconnecting their side"
        default: nil
        }
        let heading = themSide == .up || youSide == .up ? "Listening" : "Reconnecting"
        return heading + " (" + ([backendName] + [scope].compactMap { $0 }).joined(separator: ", ") + ")"
    }

    private func tearDown() {
        themSlot.set(nil)
        youSlot.set(nil)
        if youSide == .up || youSide == .failed { microphone.stop() }
        if themSide == .pending || themSide == .up || themSide == .reconnecting {
            stopSystemAudio()
        }
        if themSide != .failed { themTranscriber?.stop() }
        if youSide != .failed { youTranscriber?.stop() }
        themTranscriber = nil
        youTranscriber = nil
        awaitingSpeechPermission = []
        themSide = .off
        youSide = .off
    }

    private func stopSystemAudio() {
        let previous = lifecycle
        lifecycle = Task { [systemAudio] in
            await previous?.value
            await systemAudio.stop()
        }
    }

    // MARK: - Capture that stops mid-call

    /// Each session listens for its own capture callbacks, so an error that was
    /// already on its way when the session ended cannot land in the next one.
    private func watchCapture(session current: Int) {
        systemAudio.onError = { [weak self] failure in
            self?.systemAudioStopped(failure, session: current)
        }
        microphone.onError = { [weak self] message in
            self?.microphoneFailed(message, session: current)
        }
        microphone.onRecovered = { [weak self] in
            self?.microphoneRecovered(session: current)
        }
        systemAudio.onNotice = { [weak self] message in
            guard let self, self.session == current else { return }
            self.captureNotice = message
            self.refreshNotice()
        }
    }

    private func systemAudioStopped(_ failure: CaptureFailure, session current: Int) {
        guard session == current, themSide == .up else { return }
        guard failure.isRetryable else {
            giveUpOnSystemAudio(Problem(message: "Meeting audio stopped: \(failure.message)"), canRevive: false)
            return
        }
        themSide = .reconnecting
        themAttempts = 0
        status = listeningStatus()
        scheduleSystemAudioRestart(session: current)
    }

    private func scheduleSystemAudioRestart(session current: Int) {
        themRecovery += 1
        let recovery = themRecovery
        let delays = Self.systemAudioRetryDelays
        schedule(delays[min(themAttempts, delays.count - 1)]) { [weak self] in
            deliverOnMain { self?.restartSystemAudio(session: current, recovery: recovery) }
        }
    }

    private func isRecovering(session current: Int, recovery: Int) -> Bool {
        session == current && themSide == .reconnecting && themRecovery == recovery
    }

    /// Stops the dead stream and starts a new one through the same chain as
    /// Start and Stop, so the two never overlap. The transcriber is untouched:
    /// it keeps its state and utterance numbering across the gap.
    private func restartSystemAudio(session current: Int, recovery: Int) {
        guard isRecovering(session: current, recovery: recovery) else { return }
        let previous = lifecycle
        lifecycle = Task { [weak self, systemAudio] in
            await previous?.value
            guard let self, self.isRecovering(session: current, recovery: recovery) else { return }
            await systemAudio.stop()
            do {
                try await systemAudio.start(application: self.settings.captureAppBundleID)
                guard self.session == current, self.themSide == .reconnecting else {
                    await systemAudio.stop()
                    return
                }
                self.themSide = .up
                self.themAttempts = 0
                self.clearCaptureProblem(for: .them)
                self.status = self.listeningStatus()
            } catch {
                guard self.isRecovering(session: current, recovery: recovery) else { return }
                self.systemAudioRestartFailed(error, session: current)
            }
        }
    }

    private func systemAudioRestartFailed(_ error: Error, session current: Int) {
        if (error as? SystemAudioError) == .permissionDenied {
            giveUpOnSystemAudio(Self.problem(forSystemAudioError: error), canRevive: false)
            return
        }
        themAttempts += 1
        guard themAttempts < Self.systemAudioRetryDelays.count else {
            giveUpOnSystemAudio(Problem(message: "Meeting audio stopped and couldn't be restarted: \(error.localizedDescription)"),
                                canRevive: true)
            return
        }
        scheduleSystemAudioRestart(session: current)
    }

    /// Their side is marked failed, so the status says so (or the session ends
    /// if the microphone is down too). `canRevive` lets a wake or display change
    /// try again, which is pointless after a user stop or a permission problem.
    private func giveUpOnSystemAudio(_ problem: Problem, canRevive: Bool) {
        themSide = .failed
        themCanRevive = canRevive
        themRecovery += 1
        themSlot.set(nil)
        themTranscriber?.stop()
        reportCaptureProblem(problem, for: .them)
        stopSystemAudio()
        resolveStartup()
    }

    private func microphoneFailed(_ message: String, session current: Int) {
        guard session == current, youSide == .up else { return }
        youSide = .failed
        youSlot.set(nil)
        youTranscriber?.stop()
        reportCaptureProblem(Problem(message: "Microphone stopped: \(message)"), for: .you)
        resolveStartup()
    }

    private func microphoneRecovered(session current: Int) {
        guard session == current, youSide == .failed, let you = youTranscriber else { return }
        youSide = .up
        clearCaptureProblem(for: .you)
        you.start()
        youSlot.set(you)
        status = listeningStatus()
    }

    /// The Mac woke up or the displays changed: a good moment to bring system
    /// audio back, without waiting for the next backoff. A stream that is
    /// still up is left alone; if it died it reports that itself.
    func captureEnvironmentChanged() {
        guard listening == .listening else { return }
        switch themSide {
        case .reconnecting:
            themAttempts = 0
            themRecovery += 1
            restartSystemAudio(session: session, recovery: themRecovery)
        case .failed where themCanRevive:
            themSide = .reconnecting
            themCanRevive = false
            themAttempts = 0
            clearCaptureProblem(for: .them)
            themTranscriber?.start()
            themSlot.set(themTranscriber)
            status = listeningStatus()
            themRecovery += 1
            restartSystemAudio(session: session, recovery: themRecovery)
        default:
            break
        }
    }

    private func observeEnvironment(workspace: NotificationCenter, screens: NotificationCenter) {
        let changed: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.captureEnvironmentChanged() }
        }
        observers = [
            (workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                              queue: .main, using: changed)),
            (workspace, workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil,
                                              queue: .main, using: changed)),
            (screens, screens.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                          queue: .main, using: changed)),
        ]
    }

    // MARK: - Sides that break without saying so

    private func meter(for speaker: Speaker) -> AudioMeter {
        speaker == .them ? themMeter : youMeter
    }

    private func armWatchdog(for speaker: Speaker) {
        let reading = meter(for: speaker).reading()
        guard watchdogs[speaker] != nil else {
            watchdogs[speaker] = SideWatchdog(at: now(), reading: reading)
            return
        }
        watchdogs[speaker]?.rearm(at: now(), reading: reading)
    }

    private func scheduleWatchdog(session current: Int) {
        watchdogSchedule(Self.watchdogInterval) { [weak self] in
            deliverOnMain { self?.watchdogTick(session: current) }
        }
    }

    /// Never acts for a session that has ended, so a Stop (and its drain) is
    /// left alone. A gap far longer than the interval means the Mac slept: the
    /// silence that followed is not the sides' fault, so counting starts over.
    private func watchdogTick(session current: Int) {
        guard session == current, listening != .idle else { return }
        scheduleWatchdog(session: current)
        let time = now()
        let slept = time.timeIntervalSince(lastWatchdogTick) > Self.watchdogInterval * 3
        lastWatchdogTick = time
        for speaker in [Speaker.them, .you] {
            inspect(speaker, at: time, slept: slept)
        }
    }

    private func inspect(_ speaker: Speaker, at time: Date, slept: Bool) {
        guard (speaker == .them ? themSide : youSide) == .up, var watch = watchdogs[speaker] else { return }
        let reading = meter(for: speaker).reading()
        guard !slept, !awaitingSpeechPermission.contains(speaker) else {
            watch.rearm(at: time, reading: reading)
            watchdogs[speaker] = watch
            return
        }
        let verdict = watch.check(reading, at: time)
        watchdogs[speaker] = watch
        if !watch.isHearingAudio { levels.silence(speaker) }
        guard let verdict else { return }
        act(on: verdict, for: speaker)
    }

    private func act(on verdict: SideWatchdog.Verdict, for speaker: Speaker) {
        switch verdict {
        case .restartCapture:
            restartCapture(of: speaker)
        case .captureStillSilent:
            let source = speaker == .them ? "the meeting" : "your microphone"
            let advice = speaker == .them ? "If people are talking, stop and start listening."
                                          : "Check its input in System Settings, then stop and start listening."
            reportCaptureProblem(Problem(message: "No audio is coming from \(source). \(advice)"), for: speaker)
        case .captureResumed:
            clearCaptureProblem(for: speaker)
        case .restartTranscriber:
            guard let transcriber = speaker == .them ? themTranscriber : youTranscriber else { return }
            transcriber.stop()
            transcriber.start()
        case .transcriberStillSilent:
            let side = speaker == .them ? "Their" : "Your"
            reportCaptureProblem(Problem(message: "\(side) side is being heard but nothing is being transcribed. Stop and start listening to try again."),
                                 for: speaker)
        }
    }

    /// Their side goes through the same backoff as a stream that reports its own
    /// death; the microphone has its own, behind `reconnect()`.
    private func restartCapture(of speaker: Speaker) {
        switch speaker {
        case .them:
            systemAudioStopped("No audio came from the meeting for a while.", session: session)
        case .you:
            microphone.reconnect()
        }
    }

    /// A capture problem goes away again once that capture works, instead of
    /// lingering in the list as if it were still true.
    private func reportCaptureProblem(_ problem: Problem, for speaker: Speaker) {
        clearCaptureProblem(for: speaker)
        captureProblems[speaker] = problem
        report(problem)
    }

    private func clearCaptureProblem(for speaker: Speaker) {
        guard let problem = captureProblems.removeValue(forKey: speaker) else { return }
        problems.removeAll { $0 == problem }
    }

    private func wire(_ transcriber: LiveTranscriber, as speaker: Speaker, session current: Int) {
        transcriber.onSegment = { [weak self] segment in
            guard let self, self.session == current || self.drainingSession == current else { return }
            if self.session == current { self.heardText(segment, from: speaker) }
            self.receive(segment, from: speaker, isLive: self.session == current)
        }
        transcriber.onError = { [weak self] message in
            guard let self, self.session == current else { return }
            self.report(Problem(message: "\(speaker.rawValue): \(message)"))
        }
        transcriber.onFatal = { [weak self, weak transcriber] message in
            guard let self, let transcriber, self.session == current else { return }
            self.transcriberGaveUp(transcriber, as: speaker, message: message)
        }
        transcriber.onNotice = { [weak self] message in
            guard let self, self.session == current else { return }
            self.setNotice(message, from: speaker)
        }
    }

    /// Words arriving prove the transcriber works, and take down a report that it did not.
    private func heardText(_ segment: TranscriptSegment, from speaker: Speaker) {
        guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if watchdogs[speaker]?.noteText() == true { clearCaptureProblem(for: speaker) }
    }

    /// A transcriber that gave up will not come back by itself, so its side is
    /// marked failed and its capture released: the status says which side is
    /// left (or the session ends if both are), and a wake cannot revive it. A
    /// transcriber that has since been replaced no longer speaks for its side.
    private func transcriberGaveUp(_ transcriber: LiveTranscriber, as speaker: Speaker, message: String) {
        switch speaker {
        case .them:
            guard themTranscriber === transcriber,
                  themSide == .pending || themSide == .up || themSide == .reconnecting else { return }
            themSide = .failed
            themCanRevive = false
            themRecovery += 1
            themSlot.set(nil)
            stopSystemAudio()
        case .you:
            guard youTranscriber === transcriber, youSide == .pending || youSide == .up else { return }
            youSide = .failed
            youSlot.set(nil)
            microphone.stop()
        }
        transcriber.stop()
        reportCaptureProblem(Problem(message: "\(speaker.rawValue): \(message)"), for: speaker)
        resolveStartup()
    }

    /// Each side has its own notice, so one finishing (or failing) a model
    /// download does not wipe the other's, and the same text is shown once.
    private func setNotice(_ message: String?, from speaker: Speaker) {
        speakerNotices[speaker] = message
        refreshNotice()
    }

    /// What capture says about itself comes first, then each side's speech notice.
    private func refreshNotice() {
        let shown = [captureNotice].compactMap { $0 } + [Speaker.them, .you].compactMap { speakerNotices[$0] }
        notice = shown.isEmpty ? nil : shown.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: "\n")
    }

    private func clearNotices() {
        speakerNotices = [:]
        captureNotice = nil
        notice = nil
    }

    private func report(_ problem: Problem) {
        guard !problems.contains(problem) else { return }
        problems = Array((problems + [problem]).suffix(Self.maxProblems))
    }

    private static func problem(forSystemAudioError error: Error) -> Problem {
        guard (error as? SystemAudioError) == .permissionDenied else {
            return Problem(message: "Couldn't capture meeting audio: \(error.localizedDescription)")
        }
        return Problem(message: "Meeting audio needs Screen Recording permission. Allow Meeting Assistant in System Settings, then quit and reopen it.",
                       fix: .screenRecording)
    }

    // MARK: - Transcript

    /// Utterances that were already underway keep reporting their whole text,
    /// so they are ignored from here on instead of bringing the old words back.
    func clearTranscript() {
        let seen = Dictionary(uniqueKeysWithValues: [Speaker.them, .you].compactMap { speaker in
            transcript.highestUtterance(of: speaker).map { (speaker, $0) }
        })
        resetTranscriptAndAnswer()
        clearedThrough = seen
    }

    private func resetTranscriptAndAnswer() {
        transcript = Transcript()
        clearedThrough = [:]
        transcriptDisplay = ""
        answerTask?.cancel()
        answerRequest += 1
        answer = ""
        isAnswering = false
    }

    private func receive(_ segment: TranscriptSegment, from speaker: Speaker, isLive: Bool) {
        guard segment.utterance > (clearedThrough[speaker] ?? .min) else { return }
        let finished = transcript.apply(segment, from: speaker, at: now())
        transcriptDisplay = transcript.tail(maxCharacters: Self.displayCharacters)
        guard isLive, let finished, finished.speaker == .them,
              QuestionDetector.looksLikeQuestion(finished.text) else { return }
        autoAnswerIfDue()
    }

    // MARK: - Answers

    func answerNow() {
        let inSample = listening == .sample
        guard inSample || settings.hasAcceptedTerms else {
            onTermsNeeded?({ [weak self] in self?.answerNow() })
            return
        }
        answerTask?.cancel()
        answerRequest += 1
        let current = answerRequest
        let context = transcript.tail(maxCharacters: Self.promptCharacters)
        guard !context.isEmpty else {
            answer = "No transcript yet. Start listening first."
            isAnswering = false
            return
        }
        let stream: AsyncThrowingStream<String, Error>
        if let apiKey = settings.resolveAPIKey() {
            stream = answerer.stream(AnswerRequest(apiKey: apiKey, model: settings.model,
                                                   system: settings.systemPrompt,
                                                   user: Self.userPrompt(context)))
        } else if inSample {
            stream = nextSampleAnswer()
        } else {
            answer = settings.apiKeySource == .unreadable
                ? "Can't read your API key from the Keychain. Allow access when macOS asks, or save the key again in Settings."
                : "No API key. Add one in Settings (menu bar icon, then Settings…)."
            isAnswering = false
            return
        }
        answer = ""
        isAnswering = true
        answerTask = Task { [weak self] in
            do {
                for try await chunk in stream {
                    guard let self, self.answerRequest == current else { return }
                    self.answer += chunk
                }
                self?.finishAnswer(current, error: nil)
            } catch {
                self?.finishAnswer(current, error: error)
            }
        }
    }

    private func finishAnswer(_ request: Int, error: Error?) {
        guard request == answerRequest else { return }
        isAnswering = false
        guard let error, !(error is CancellationError) else { return }
        let message = "Error: \(error.localizedDescription)"
        answer = answer.isEmpty ? message : answer + "\n\n" + message
    }

    private func autoAnswerIfDue() {
        guard settings.autoAnswer, !isAnswering,
              now().timeIntervalSince(lastAutoAnswer) >= Self.autoAnswerInterval else { return }
        lastAutoAnswer = now()
        answerNow()
    }

    // MARK: - Sample meeting

    /// Plays the scripted call from `SampleMeeting`, answering its questions as
    /// they come, so the app can be tried without a meeting or permissions.
    func startSample() {
        guard listening == .idle else { return }
        session += 1
        listening = .sample
        status = "Sample meeting (nothing is recorded)"
        problems = []
        clearNotices()
        resetTranscriptAndAnswer()
        sampleAnswersShown = 0
        scheduleSampleLine(0, session: session)
    }

    private func scheduleSampleLine(_ index: Int, session current: Int) {
        schedule(SampleMeeting.lineInterval) { [weak self] in
            deliverOnMain { self?.showSampleLine(index, session: current) }
        }
    }

    private func showSampleLine(_ index: Int, session current: Int) {
        guard session == current, listening == .sample else { return }
        let line = SampleMeeting.lines[index]
        let segment = TranscriptSegment(utterance: index, text: line.text, isFinal: true)
        let finished = transcript.apply(segment, from: line.speaker, at: now())
        transcriptDisplay = transcript.tail(maxCharacters: Self.displayCharacters)
        if let finished, finished.speaker == .them, QuestionDetector.looksLikeQuestion(finished.text) {
            answerNow()
        }
        if index + 1 < SampleMeeting.lines.count {
            scheduleSampleLine(index + 1, session: current)
        } else {
            listening = .idle
            status = "Sample meeting finished"
        }
    }

    private func nextSampleAnswer() -> AsyncThrowingStream<String, Error> {
        let answers = SampleMeeting.sampleAnswers
        let text = answers[min(sampleAnswersShown, answers.count - 1)]
        sampleAnswersShown += 1
        return SampleMeeting.streamAnswer(SampleMeeting.sampleAnswerIntro + text, wordDelay: sampleWordDelay)
    }

    private static func userPrompt(_ context: String) -> String {
        AnswerPrompt.user(transcript: context)
    }

    // MARK: - Privacy

    private static let settingsRecheckInterval: TimeInterval = 0.25
    /// Each restart numbers its utterances from here, so a new backend's
    /// utterance 0 never lands on an earlier backend's open turn.
    private static let restartUtteranceStride = 1_000_000

    private struct Replacement {
        let speaker: Speaker
        let transcriber: LiveTranscriber
        let started: Bool
    }

    /// What the running session's transcribers were built from.
    @ObservationIgnored private var activePlan = SpeechPlan.analyzer
    @ObservationIgnored private var restartGeneration = 0
    @ObservationIgnored private var settingsObserver: AnyCancellable?

    /// Runs at the start of every listening session, before any transcriber or
    /// audio exists: reads the keys now, so a Keychain prompt never lands
    /// mid-call, and remembers which backend this session is about to use.
    private func beginPrivacySession() {
        settings.loadKeysForListening()
        activePlan = TranscriberFactory.plan(for: settings)
        observeSettings()
    }

    private func observeSettings() {
        guard settingsObserver == nil else { return }
        settingsObserver = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.speechSettingsMayHaveChanged() }
    }

    /// Turning Deepgram off, removing its key, or revoking Apple's servers
    /// takes effect now, not at the next Start. Turning Deepgram on is left
    /// for the next Start, as Settings says.
    private func speechSettingsMayHaveChanged() {
        guard listening == .starting || listening == .listening else { return }
        let plan = TranscriberFactory.plan(for: settings)
        guard plan != activePlan, plan != .deepgram else { return }
        guard listening == .listening else {
            schedule(Self.settingsRecheckInterval) { [weak self] in
                deliverOnMain { self?.speechSettingsMayHaveChanged() }
            }
            return
        }
        restartTranscribers(to: plan)
    }

    /// Replaces the transcriber on every side that is capturing with one built
    /// from the current settings. Audio is cut off from the old one first, so
    /// nothing more reaches a backend the user switched off.
    private func restartTranscribers(to plan: SpeechPlan) {
        let current = session
        activePlan = plan
        restartGeneration += 1
        let offset = restartGeneration * Self.restartUtteranceStride
        var replaced: [Replacement] = []
        for speaker in [Speaker.them, .you] {
            let started: Bool
            switch speaker == .them ? themSide : youSide {
            // A reconnecting side keeps its transcriber running while capture
            // comes back, so it is replaced exactly like a side that is up.
            case .up, .reconnecting: started = true
            case .pending: started = speaker == .them
            case .off, .failed: continue
            }
            guard let old = speaker == .them ? themTranscriber : youTranscriber else { continue }
            (speaker == .them ? themSlot : youSlot).set(nil)
            if started { old.stop() }
            let fresh = makeTranscriber(speaker)
            wire(fresh, as: speaker, session: current)
            let forward = fresh.onSegment
            fresh.onSegment = { segment in
                forward?(TranscriptSegment(utterance: segment.utterance + offset, text: segment.text,
                                           isFinal: segment.isFinal))
            }
            if speaker == .them { themTranscriber = fresh } else { youTranscriber = fresh }
            if started { awaitingSpeechPermission.insert(speaker) }
            replaced.append(Replacement(speaker: speaker, transcriber: fresh, started: started))
        }
        guard let first = replaced.first else { return }
        backendName = first.transcriber.backendName
        if listening == .listening { status = listeningStatus() }
        first.transcriber.requestAuthorization { [weak self] granted in
            deliverOnMain { self?.replacementsAuthorized(granted, replaced: replaced, session: current) }
        }
    }

    private func replacementsAuthorized(_ granted: Bool, replaced: [Replacement], session current: Int) {
        guard session == current else { return }
        awaitingSpeechPermission.subtract(replaced.map(\.speaker))
        guard granted else {
            report(Problem(message: "Speech Recognition permission is off, so listening stopped. Allow Meeting Assistant in System Settings.",
                           fix: .speechRecognition))
            stop()
            return
        }
        for item in replaced where item.started {
            let side = item.speaker == .them ? themSide : youSide
            let still = item.speaker == .them ? themTranscriber : youTranscriber
            guard side == .up || side == .pending, still === item.transcriber else { continue }
            item.transcriber.start()
            (item.speaker == .them ? themSlot : youSlot).set(item.transcriber)
        }
    }
}
