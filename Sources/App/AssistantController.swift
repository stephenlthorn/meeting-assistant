import AVFoundation
import Foundation
import Observation

/// Which side of the conversation a transcript line came from.
enum Speaker: String {
    case you = "You"
    case them = "Them"
}

enum ListeningState: Equatable {
    case idle, starting, listening
}

/// Orchestrates the pipeline: system audio (them) and the microphone (you)
/// feed two transcribers whose segments merge into one speaker-labeled
/// transcript; on demand (or auto-answer) the recent transcript goes to Claude.
///
/// Everything here runs on the main actor except audio, which capture threads
/// hand to the current transcribers through lock-protected slots. Each Start
/// and Stop begins a new session, and callbacks from older sessions are
/// ignored. Starting and stopping system audio is chained, so a Start never
/// overlaps the previous Stop.
@MainActor
@Observable
final class AssistantController {
    static let displayCharacters = 1_500
    static let promptCharacters = 4_000
    static let autoAnswerInterval: TimeInterval = 6
    private static let maxProblems = 3

    private(set) var listening: ListeningState = .idle
    private(set) var status = "Idle"
    private(set) var problems: [Problem] = []
    private(set) var notice: String?
    private(set) var transcriptDisplay = ""
    private(set) var answer = ""
    private(set) var isAnswering = false

    var isListening: Bool { listening != .idle }
    var transcriptText: String { transcript.text }

    private enum SideState { case off, pending, up, failed }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let systemAudio: SystemAudioCapturing
    @ObservationIgnored private let microphone: MicrophoneCapturing
    @ObservationIgnored private let makeTranscriber: @MainActor (Speaker) -> LiveTranscriber
    @ObservationIgnored private let answerer: AnswerStreaming
    @ObservationIgnored private let now: () -> Date

    @ObservationIgnored private let themSlot = TranscriberSlot()
    @ObservationIgnored private let youSlot = TranscriberSlot()
    @ObservationIgnored private var themTranscriber: LiveTranscriber?
    @ObservationIgnored private var youTranscriber: LiveTranscriber?
    @ObservationIgnored private var themSide = SideState.off
    @ObservationIgnored private var youSide = SideState.off
    @ObservationIgnored private var backendName = ""
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var lifecycle: Task<Void, Never>?

    @ObservationIgnored private var transcript = Transcript()
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    @ObservationIgnored private var answerRequest = 0
    @ObservationIgnored private var lastAutoAnswer = Date.distantPast

    init(settings: AppSettings,
         systemAudio: SystemAudioCapturing,
         microphone: MicrophoneCapturing,
         makeTranscriber: @escaping @MainActor (Speaker) -> LiveTranscriber,
         answerer: AnswerStreaming,
         now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.makeTranscriber = makeTranscriber
        self.answerer = answerer
        self.now = now
        systemAudio.onBuffer = { [themSlot] buffer in themSlot.append(buffer) }
        microphone.onBuffer = { [youSlot] buffer in youSlot.append(buffer) }
        systemAudio.onError = { [weak self] message in
            self?.report(Problem(message: "Meeting audio stopped: \(message)"))
        }
        microphone.onError = { [weak self] message in
            self?.report(Problem(message: "Microphone stopped: \(message)"))
        }
    }

    static func live(settings: AppSettings = .shared) -> AssistantController {
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
        session += 1
        let current = session
        listening = .starting
        status = "Starting…"
        problems = []
        notice = nil
        resetTranscriptAndAnswer()

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
        session += 1
        tearDown()
        listening = .idle
        status = "Stopped"
        notice = nil
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
                try await systemAudio.start()
                guard let self, self.session == current else {
                    await systemAudio.stop()
                    return
                }
                self.themSide = .up
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
        case (.up, _), (_, .up):
            listening = .listening
            status = listeningStatus()
        case (.failed, .failed):
            session += 1
            tearDown()
            listening = .idle
            status = "Not listening"
        default:
            break
        }
    }

    private func listeningStatus() -> String {
        let scope: String? = switch (themSide, youSide) {
        case (.up, .failed): "their side only"
        case (.failed, .up): "your side only"
        default: nil
        }
        return "Listening (" + ([backendName] + [scope].compactMap { $0 }).joined(separator: ", ") + ")"
    }

    private func tearDown() {
        themSlot.set(nil)
        youSlot.set(nil)
        if youSide == .up { microphone.stop() }
        if themSide == .pending || themSide == .up {
            let previous = lifecycle
            lifecycle = Task { [systemAudio] in
                await previous?.value
                await systemAudio.stop()
            }
        }
        themTranscriber?.stop()
        youTranscriber?.stop()
        themTranscriber = nil
        youTranscriber = nil
        themSide = .off
        youSide = .off
    }

    private func wire(_ transcriber: LiveTranscriber, as speaker: Speaker, session current: Int) {
        transcriber.onSegment = { [weak self] segment in
            guard let self, self.session == current else { return }
            self.receive(segment, from: speaker)
        }
        transcriber.onError = { [weak self] message in
            guard let self, self.session == current else { return }
            self.report(Problem(message: "\(speaker.rawValue): \(message)"))
        }
        transcriber.onNotice = { [weak self] message in
            guard let self, self.session == current else { return }
            self.notice = message
        }
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

    func clearTranscript() {
        resetTranscriptAndAnswer()
    }

    private func resetTranscriptAndAnswer() {
        transcript = Transcript()
        transcriptDisplay = ""
        answerTask?.cancel()
        answerRequest += 1
        answer = ""
        isAnswering = false
    }

    private func receive(_ segment: TranscriptSegment, from speaker: Speaker) {
        let finished = transcript.apply(segment, from: speaker, at: now())
        transcriptDisplay = transcript.tail(maxCharacters: Self.displayCharacters)
        guard let finished, finished.speaker == .them,
              QuestionDetector.looksLikeQuestion(finished.text) else { return }
        autoAnswerIfDue()
    }

    // MARK: - Answers

    func answerNow() {
        answerTask?.cancel()
        answerRequest += 1
        let current = answerRequest
        let context = transcript.tail(maxCharacters: Self.promptCharacters)
        guard !context.isEmpty else {
            answer = "No transcript yet. Start listening first."
            isAnswering = false
            return
        }
        guard let apiKey = settings.resolveAPIKey() else {
            answer = "No API key. Add one in Settings (menu bar icon, then Settings…)."
            isAnswering = false
            return
        }
        answer = ""
        isAnswering = true
        let stream = answerer.stream(AnswerRequest(apiKey: apiKey, model: settings.model,
                                                   system: settings.systemPrompt,
                                                   user: Self.userPrompt(context)))
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

    private static func userPrompt(_ context: String) -> String {
        """
        Live conversation transcript so far (You = me, Them = the other participants):

        \(context)

        Based on the latest exchange, give me help right now. Be concise.
        """
    }
}
