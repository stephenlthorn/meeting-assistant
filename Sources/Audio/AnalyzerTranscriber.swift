import AVFoundation
import Foundation
import Speech

/// A started speech-analysis pipeline: feed it audio, read its results.
protocol AnalyzerPipeline: AnyObject {
    /// The format `feed` expects; SpeechAnalyzer does not resample.
    var audioFormat: AVAudioFormat { get }
    var results: AsyncThrowingStream<(text: String, isFinal: Bool), Error> { get }
    func feed(_ buffer: AVAudioPCMBuffer)
    func finish() async
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
final class AnalyzerTranscriber: LiveTranscriber {
    let backendName = "on-device"
    var onSegment: (@MainActor (TranscriptSegment) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onNotice: (@MainActor (String?) -> Void)?

    private let makePipeline: AnalyzerPipelineFactory
    private let lock = NSLock()
    private var running = false
    private var pipeline: AnalyzerPipeline?
    private var task: Task<Void, Never>?
    private var converter: AVAudioConverter?

    init(makePipeline: @escaping AnalyzerPipelineFactory) {
        self.makePipeline = makePipeline
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
        lock.withLock { running = true }
        task = Task { [weak self, makePipeline] in
            let pipeline: AnalyzerPipeline
            do {
                pipeline = try await makePipeline { progress in self?.notify(progress) }
            } catch {
                if self?.isRunning == true {
                    self?.report("SpeechAnalyzer setup failed: \(error.localizedDescription)")
                }
                return
            }
            guard let self, self.adopt(pipeline) else {
                await pipeline.finish()
                return
            }
            do {
                try await self.deliverResults(of: pipeline)
            } catch {
                if self.isRunning { self.report("Transcription stream error: \(error.localizedDescription)") }
            }
        }
    }

    func stop() {
        let pipeline = lock.withLock { () -> AnalyzerPipeline? in
            running = false
            defer { self.pipeline = nil }
            return self.pipeline
        }
        task?.cancel()
        task = nil
        if let pipeline {
            Task { await pipeline.finish() }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let pipeline = lock.withLock({ running ? pipeline : nil }),
              let converted = convert(buffer, to: pipeline.audioFormat) else { return }
        pipeline.feed(converted)
    }

    // MARK: - Private

    private var isRunning: Bool { lock.withLock { running } }

    /// Takes the pipeline only if still running, atomically with `stop()`.
    private func adopt(_ pipeline: AnalyzerPipeline) -> Bool {
        lock.withLock {
            guard running else { return false }
            self.pipeline = pipeline
            return true
        }
    }

    private func deliverResults(of pipeline: AnalyzerPipeline) async throws {
        var utterance = 0
        for try await result in pipeline.results {
            guard isRunning else { return }
            let segment = TranscriptSegment(utterance: utterance, text: result.text, isFinal: result.isFinal)
            if result.isFinal { utterance += 1 }
            let onSegment = self.onSegment
            deliverOnMain { onSegment?(segment) }
        }
    }

    private func report(_ message: String) {
        let onError = self.onError
        deliverOnMain { onError?(message) }
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
    private let input: AsyncStream<AnalyzerInput>.Continuation

    private init(audioFormat: AVAudioFormat,
                 results: AsyncThrowingStream<(text: String, isFinal: Bool), Error>,
                 analyzer: SpeechAnalyzer,
                 input: AsyncStream<AnalyzerInput>.Continuation) {
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
            try await request.downloadAndInstall()
            onProgress(nil)
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
        let (inputSequence, input) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputSequence)
        return SpeechAnalyzerPipeline(audioFormat: format, results: results, analyzer: analyzer, input: input)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
    }
}
