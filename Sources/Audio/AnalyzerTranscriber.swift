import AVFoundation
import Foundation
import Speech

/// A started speech-analysis pipeline: feed it audio, read its results.
protocol AnalyzerPipeline: AnyObject {
    /// The format `feed` expects; SpeechAnalyzer does not resample.
    var audioFormat: AVAudioFormat { get }
    var results: AsyncThrowingStream<(text: String, isFinal: Bool), Error> { get }
    /// Queues audio for analysis. Returns false when the analyzer is so far
    /// behind that older queued audio had to be dropped to make room.
    @discardableResult
    func feed(_ buffer: AVAudioPCMBuffer) -> Bool
    /// Ends the input and lets the analyzer finish what it has already heard:
    /// its last results are reported, then `results` ends.
    func finish() async
    /// Shuts the analyzer down at once; anything not yet reported is lost.
    func cancel() async
}

/// Builds a pipeline, reporting progress such as a model download (nil clears it).
typealias AnalyzerPipelineFactory = (_ onProgress: @escaping (String?) -> Void) async throws -> AnalyzerPipeline

/// Live, on-device transcription using Apple's SpeechAnalyzer + SpeechTranscriber
/// (macOS 26+). Built for long-form conversational audio and true streaming.
///
/// Setting up can take minutes the first time while the speech model
/// downloads; that shows as a notice, audio is dropped until the pipeline is
/// ready, and stopping during setup shuts the pipeline down as soon as it
/// arrives instead of leaving it running.
///
/// Stopping lets the analyzer finish what it has already heard, so the last
/// sentence of a call still arrives, and shuts it down after `drainTimeout`.
///
/// A pipeline that fails to build, errors, or ends by itself is rebuilt with
/// backoff, and the problem is reported once if it keeps happening. Utterance
/// numbers belong to this object, not to a pipeline, so a rebuilt pipeline
/// never reuses a number the transcript already holds.
final class AnalyzerTranscriber: LiveTranscriber {
    static let failuresBeforeReporting = 3
    static let defaultDrainTimeout: TimeInterval = 1.5
    private static let maximumBackoff: TimeInterval = 30

    let backendName = "on-device"
    var onSegment: (@MainActor (TranscriptSegment) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onFatal: (@MainActor (String) -> Void)?
    var onNotice: (@MainActor (String?) -> Void)?

    private let makePipeline: AnalyzerPipelineFactory
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let drainTimeout: TimeInterval
    private let lock = NSLock()
    // Guarded by `lock`. `run` identifies one start() span so work left over
    // from an earlier span can tell it is stale; `draining` means stop() was
    // called and the pipeline is still reporting what it already heard.
    private var running = false
    private var draining = false
    private var run = 0
    private var pipeline: AnalyzerPipeline?
    private var task: Task<Void, Never>?
    private var failures = 0
    private var utterance = 0
    private var reportedFallingBehind = false
    private var converter: AVAudioConverter?

    init(makePipeline: @escaping AnalyzerPipelineFactory,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = runAfter,
         drainTimeout: TimeInterval = AnalyzerTranscriber.defaultDrainTimeout) {
        self.makePipeline = makePipeline
        self.schedule = schedule
        self.drainTimeout = drainTimeout
    }

    @available(macOS 26, *)
    convenience init(localeIdentifier: String = "en-US") {
        self.init(makePipeline: { onProgress in
            try await SpeechAnalyzerPipeline.make(localeIdentifier: localeIdentifier, onProgress: onProgress)
        })
    }

    /// SpeechAnalyzer runs fully on-device and does not use the Speech Recognition
    /// service, so no Speech authorization is required. Audio here comes from
    /// system or mic capture, whose own permissions are requested elsewhere.
    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        completion(true)
    }

    func start() {
        let current = lock.withLock { () -> Int in
            running = true
            draining = false
            run += 1
            failures = 0
            reportedFallingBehind = false
            return run
        }
        launch(run: current)
    }

    func stop() {
        let (pipeline, settingUp) = lock.withLock { () -> (AnalyzerPipeline?, Task<Void, Never>?) in
            running = false
            defer { self.pipeline = nil }
            draining = self.pipeline != nil
            return (self.pipeline, self.pipeline == nil ? task : nil)
        }
        settingUp?.cancel()
        guard let pipeline else { return }
        Task { await pipeline.finish() }
        schedule(drainTimeout) { Task { await pipeline.cancel() } }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let pipeline = lock.withLock({ running ? pipeline : nil }),
              let converted = convert(buffer, to: pipeline.audioFormat) else { return }
        if !pipeline.feed(converted) { reportFallingBehind() }
    }

    // MARK: - Pipeline lifecycle

    private func isCurrent(_ run: Int) -> Bool { lock.withLock { running && self.run == run } }

    /// Results still count while a stopped pipeline finishes what it heard.
    private func canDeliver(_ run: Int) -> Bool { lock.withLock { (running || draining) && self.run == run } }

    /// Setup can take minutes (a model download), so the task is kept: stopping
    /// before there is a pipeline cancels it instead of finishing the download.
    private func launch(run: Int) {
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.attempt(run: run)
        }
        lock.withLock { if self.run == run { self.task = task } }
    }

    /// Builds one pipeline and delivers its results until it ends.
    private func attempt(run: Int) async {
        let pipeline: AnalyzerPipeline
        do {
            pipeline = try await makePipeline { [weak self] progress in self?.notify(progress) }
        } catch {
            notify(nil)
            guard isCurrent(run) else { return }
            failed("SpeechAnalyzer setup failed: \(error.localizedDescription)",
                   retryable: !(error is AnalyzerSetupError), run: run)
            return
        }
        guard adopt(pipeline, run: run) else {
            await pipeline.cancel()
            return
        }
        let message: String
        do {
            try await deliverResults(of: pipeline, run: run)
            message = "Transcription stopped unexpectedly."
        } catch {
            message = "Transcription stream error: \(error.localizedDescription)"
        }
        await pipeline.cancel()
        guard isCurrent(run) else { return }
        lock.withLock { self.pipeline = nil }
        failed(message, retryable: true, run: run)
    }

    /// Takes the pipeline only if still running, atomically with `stop()`.
    private func adopt(_ pipeline: AnalyzerPipeline, run: Int) -> Bool {
        lock.withLock {
            guard running, self.run == run else { return false }
            self.pipeline = pipeline
            return true
        }
    }

    private func failed(_ message: String, retryable: Bool, run: Int) {
        let count = lock.withLock { () -> Int in
            failures += 1
            return failures
        }
        guard retryable else {
            fatal(message)
            return
        }
        if count == Self.failuresBeforeReporting { report(message) }
        let delay = min(Self.maximumBackoff, pow(2, Double(count - 1)))
        schedule(delay) { [weak self] in
            guard let self, self.isCurrent(run) else { return }
            self.launch(run: run)
        }
    }

    private func deliverResults(of pipeline: AnalyzerPipeline, run: Int) async throws {
        for try await result in pipeline.results {
            guard canDeliver(run) else { return }
            let segment = lock.withLock { () -> TranscriptSegment in
                failures = 0
                let segment = TranscriptSegment(utterance: utterance, text: result.text, isFinal: result.isFinal)
                if result.isFinal { utterance += 1 }
                return segment
            }
            let onSegment = self.onSegment
            deliverOnMain { onSegment?(segment) }
        }
    }

    private func reportFallingBehind() {
        let first = lock.withLock { () -> Bool in
            defer { reportedFallingBehind = true }
            return !reportedFallingBehind
        }
        if first { report("Speech analysis can't keep up, so some audio is being skipped.") }
    }

    private func report(_ message: String) {
        let onError = self.onError
        deliverOnMain { onError?(message) }
    }

    /// Reported like any problem, and also announced as the end of this
    /// transcriber, so the owner can show the side as failed.
    private func fatal(_ message: String) {
        let onError = self.onError
        let onFatal = self.onFatal
        deliverOnMain {
            onError?(message)
            onFatal?(message)
        }
    }

    private func notify(_ message: String?) {
        let onNotice = self.onNotice
        deliverOnMain { onNotice?(message) }
    }

    /// SpeechAnalyzer does not resample its input, so each capture buffer is
    /// converted to the analyzer's format first. Runs on the capture thread.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

enum AnalyzerSetupError: LocalizedError {
    case unsupportedLocale, noAudioFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale: "SpeechAnalyzer has no model for this language."
        case .noAudioFormat: "No compatible audio format for SpeechAnalyzer."
        }
    }
}

/// The real SpeechAnalyzer pipeline. Requires the macOS 26 SDK (Xcode 26) to build.
@available(macOS 26, *)
final class SpeechAnalyzerPipeline: AnalyzerPipeline {
    let audioFormat: AVAudioFormat
    let results: AsyncThrowingStream<(text: String, isFinal: Bool), Error>
    private let analyzer: SpeechAnalyzer
    private let input: BoundedFeed<AnalyzerInput>

    /// About half a minute of microphone-sized buffers: enough to ride out a
    /// stall, small enough that a model that cannot keep up cannot eat the Mac's memory.
    static let maximumQueuedBuffers = 400

    private init(audioFormat: AVAudioFormat,
                 results: AsyncThrowingStream<(text: String, isFinal: Bool), Error>,
                 analyzer: SpeechAnalyzer,
                 input: BoundedFeed<AnalyzerInput>) {
        self.audioFormat = audioFormat
        self.results = results
        self.analyzer = analyzer
        self.input = input
    }

    static func make(localeIdentifier: String,
                     onProgress: @escaping (String?) -> Void) async throws -> AnalyzerPipeline {
        let wanted = Locale(identifier: localeIdentifier).identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = supported.first(where: { $0.identifier(.bcp47) == wanted })
                ?? supported.first(where: { $0.identifier(.bcp47).hasPrefix("en") }) else {
            throw AnalyzerSetupError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onProgress("Downloading the on-device speech model…")
            defer { onProgress(nil) }
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AnalyzerSetupError.noAudioFormat
        }

        // Start consuming results before any audio is fed.
        let results = AsyncThrowingStream<(text: String, isFinal: Bool), Error> { continuation in
            let reader = Task {
                do {
                    for try await result in transcriber.results {
                        continuation.yield((String(result.text.characters), result.isFinal))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
        let input = BoundedFeed<AnalyzerInput>(limit: maximumQueuedBuffers)
        try await analyzer.start(inputSequence: input.stream)
        return SpeechAnalyzerPipeline(audioFormat: format, results: results, analyzer: analyzer, input: input)
    }

    func feed(_ buffer: AVAudioPCMBuffer) -> Bool {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
    }
}
