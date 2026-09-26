import AVFoundation
import Foundation
import Speech

/// One running recognition request.
protocol SpeechRecognitionSession: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    /// Stops taking audio and lets the recognizer deliver its final result.
    func finish()
    func cancel()
}

/// The part of SFSpeechRecognizer the transcriber needs, so tests can drive it.
protocol SpeechRecognitionEngine {
    var isAvailable: Bool { get }
    var supportsOnDeviceRecognition: Bool { get }
    /// Calls back on the main thread.
    func requestAuthorization(_ completion: @escaping (Bool) -> Void)
    /// `onResult(text, isFinal)` and `onError` may arrive on any thread.
    func startSession(onResult: @escaping (String, Bool) -> Void,
                      onError: @escaping (Error) -> Void) -> SpeechRecognitionSession
}

/// Speech-to-text over a live stream of audio buffers using Apple's Speech
/// framework (SFSpeechRecognizer): the macOS 14–15 fallback, since macOS 26+
/// uses AnalyzerTranscriber.
///
/// A recognition request reports its whole text so far until it ends, so each
/// request is ended at a pause after speech (or after 45 s) and a new one
/// starts. Every request is its own utterance, which keeps the two sides of
/// the conversation interleaved and gives auto-answer a final result per
/// sentence. Requests that fail straight away are retried with backoff, and
/// the failure is reported if it keeps happening.
final class LegacySpeechTranscriber: LiveTranscriber {
    static let speechLevel: Float = 0.008 // about -42 dBFS
    static let pauseToEndRequest: TimeInterval = 0.8
    static let minimumRequestLength: TimeInterval = 1.5
    static let maximumRequestLength: TimeInterval = 45
    static let failuresBeforeReporting = 3
    private static let quickFailure: TimeInterval = 2
    private static let maximumBackoff: TimeInterval = 30

    let backendName = "on-device"
    var onSegment: (@MainActor (TranscriptSegment) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onNotice: (@MainActor (String?) -> Void)?

    private let engine: SpeechRecognitionEngine
    private let queue: DispatchQueue
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    // Only touched on `queue`.
    private var running = false
    private var session: SpeechRecognitionSession?
    private var generation = 0
    private var sessionStart = Date.distantPast
    private var sessionHasResults = false
    private var lastSpeech: Date?
    private var consecutiveFailures = 0

    init(engine: SpeechRecognitionEngine,
         queue: DispatchQueue = DispatchQueue(label: "meetingassistant.speech"),
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = runAfter) {
        self.engine = engine
        self.queue = queue
        self.now = now
        self.schedule = schedule
    }

    convenience init(localeIdentifier: String = "en-US") {
        self.init(engine: AppleSpeechEngine(localeIdentifier: localeIdentifier))
    }

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        engine.requestAuthorization(completion)
    }

    func start() {
        queue.async { [self] in
            guard engine.isAvailable else {
                report("Speech recognition isn't available for this language right now.")
                return
            }
            if !engine.supportsOnDeviceRecognition {
                notify("On-device speech isn't available for this language, so audio goes to Apple's servers.")
            }
            running = true
            consecutiveFailures = 0
            beginSession()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            session?.finish()
            session = nil
        }
    }

    /// Pauses are timed by when audio arrives, not when the queue gets to it.
    func append(_ buffer: AVAudioPCMBuffer) {
        let time = now()
        queue.async { [self] in
            guard running, session != nil else { return }
            if AudioMath.rms(buffer) >= Self.speechLevel { lastSpeech = time }
            if shouldEndRequest(at: time) {
                session?.finish()
                beginSession()
            }
            session?.append(buffer)
        }
    }

    // MARK: - Requests (on `queue`)

    private func shouldEndRequest(at time: Date) -> Bool {
        let length = time.timeIntervalSince(sessionStart)
        if length >= Self.maximumRequestLength { return true }
        guard let lastSpeech, length >= Self.minimumRequestLength else { return false }
        return time.timeIntervalSince(lastSpeech) >= Self.pauseToEndRequest
    }

    private func beginSession() {
        generation += 1
        let id = generation
        sessionStart = now()
        sessionHasResults = false
        lastSpeech = nil
        session = engine.startSession(
            onResult: { [weak self] text, isFinal in
                self?.queue.async { self?.received(text, isFinal: isFinal, session: id) }
            },
            onError: { [weak self] error in
                self?.queue.async { self?.failed(error, session: id) }
            })
    }

    /// Results from an earlier request still count: its final result finishes
    /// its own utterance.
    private func received(_ text: String, isFinal: Bool, session id: Int) {
        if id == generation {
            sessionHasResults = true
            consecutiveFailures = 0
        }
        let segment = TranscriptSegment(utterance: id, text: text, isFinal: isFinal)
        let onSegment = self.onSegment
        deliverOnMain { onSegment?(segment) }
    }

    /// Errors only matter for the current request; an earlier request ending
    /// with an error must not restart the one that replaced it.
    private func failed(_ error: Error, session id: Int) {
        guard running, id == generation else { return }
        session = nil
        let failedQuickly = !sessionHasResults && now().timeIntervalSince(sessionStart) < Self.quickFailure
        guard failedQuickly else {
            beginSession()
            return
        }
        consecutiveFailures += 1
        if consecutiveFailures == Self.failuresBeforeReporting {
            report("Speech recognition keeps failing: \(error.localizedDescription)")
        }
        let delay = min(Self.maximumBackoff, 0.5 * pow(2, Double(consecutiveFailures - 1)))
        schedule(delay) { [weak self] in
            self?.queue.async { self?.retry(after: id) }
        }
    }

    private func retry(after failedGeneration: Int) {
        guard running, session == nil, generation == failedGeneration else { return }
        beginSession()
    }

    private func report(_ message: String) {
        let onError = self.onError
        deliverOnMain { onError?(message) }
    }

    private func notify(_ message: String) {
        let onNotice = self.onNotice
        deliverOnMain { onNotice?(message) }
    }
}

/// SFSpeechRecognizer behind SpeechRecognitionEngine.
final class AppleSpeechEngine: SpeechRecognitionEngine {
    private let recognizer: SFSpeechRecognizer?

    init(localeIdentifier: String) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    var isAvailable: Bool { recognizer?.isAvailable ?? false }
    var supportsOnDeviceRecognition: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    static func makeRequest(onDevice: Bool) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = onDevice
        return request
    }

    func startSession(onResult: @escaping (String, Bool) -> Void,
                      onError: @escaping (Error) -> Void) -> SpeechRecognitionSession {
        let request = Self.makeRequest(onDevice: supportsOnDeviceRecognition)
        let task = recognizer?.recognitionTask(with: request) { result, error in
            if let result { onResult(result.bestTranscription.formattedString, result.isFinal) }
            if let error { onError(error) }
        }
        return AppleSpeechSession(request: request, task: task)
    }
}

private final class AppleSpeechSession: SpeechRecognitionSession {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let task: SFSpeechRecognitionTask?

    init(request: SFSpeechAudioBufferRecognitionRequest, task: SFSpeechRecognitionTask?) {
        self.request = request
        self.task = task
    }

    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
    func finish() { request.endAudio() }
    func cancel() { task?.cancel() }
}
