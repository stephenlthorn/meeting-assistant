import Foundation
import AVFoundation
import Speech

/// Live, on-device transcription using Apple's SpeechAnalyzer + SpeechTranscriber
/// (macOS 26+). Built for long-form conversational audio and true streaming, so
/// it replaces the segment-rotation hack the legacy backend needs.
///
/// Requires the macOS 26 SDK (Xcode 26) to build. The factory only instantiates
/// this class behind `#available(macOS 26, *)`.
///
/// A few SpeechAnalyzer symbol names moved between betas; if the build complains,
/// the likely spots are `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`,
/// `AssetInventory.assetInstallationRequest(supporting:)`, and
/// `analyzer.start(inputSequence:)`. They match Apple's WWDC25 sample as of the
/// macOS 26 release.
@available(macOS 26, *)
final class AnalyzerTranscriber: LiveTranscriber {
    let backendName = "on-device"
    var onSegment: (@MainActor (TranscriptSegment) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onNotice: (@MainActor (String?) -> Void)?

    private let localeIdentifier: String
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private var running = false
    private let lock = NSLock()

    init(localeIdentifier: String = "en-US") {
        self.localeIdentifier = localeIdentifier
    }

    /// SpeechAnalyzer runs fully on-device and does not use the Speech Recognition
    /// service, so no Speech authorization is required. Audio here comes from
    /// system or mic capture, whose own permissions are requested elsewhere.
    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        completion(true)
    }

    func start() {
        running = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.setUpAndRun()
            } catch {
                let onError = self.onError
                deliverOnMain { onError?("SpeechAnalyzer setup failed: \(error.localizedDescription)") }
            }
        }
    }

    func stop() {
        running = false
        lock.lock()
        continuation?.finish()
        continuation = nil
        lock.unlock()
        resultsTask?.cancel()
        resultsTask = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        Task { await analyzer?.cancelAndFinishNow() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let cont = continuation
        let format = analyzerFormat
        lock.unlock()
        guard running, let cont, let format, let converted = convert(buffer, to: format) else { return }
        cont.yield(AnalyzerInput(buffer: converted))
    }

    // MARK: - Setup

    private func setUpAndRun() async throws {
        // 1. Resolve a supported locale.
        let wanted = Locale(identifier: localeIdentifier).identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = supported.first(where: { $0.identifier(.bcp47) == wanted })
                ?? supported.first(where: { $0.identifier(.bcp47).hasPrefix("en") }) else {
            throw NSError(domain: "AnalyzerTranscriber", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "SpeechAnalyzer has no model for this locale."])
        }

        // 2. Build the transcriber and make sure its model is installed.
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        self.transcriber = transcriber
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // 3. Build the analyzer and learn the audio format it expects.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "AnalyzerTranscriber", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No compatible audio format for SpeechAnalyzer."])
        }

        // 4. Wire the input stream, then start consuming results BEFORE feeding audio.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.lock()
        self.analyzerFormat = format
        self.continuation = continuation
        lock.unlock()

        resultsTask = Task { [weak self] in
            guard let self, let transcriber = self.transcriber else { return }
            var utterance = 0
            do {
                for try await result in transcriber.results {
                    let segment = TranscriptSegment(utterance: utterance, text: String(result.text.characters),
                                                    isFinal: result.isFinal)
                    if result.isFinal { utterance += 1 }
                    let onSegment = self.onSegment
                    deliverOnMain { onSegment?(segment) }
                }
            } catch {
                if self.running {
                    let onError = self.onError
                    deliverOnMain { onError?("Transcription stream error: \(error.localizedDescription)") }
                }
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    // MARK: - Audio conversion

    /// SpeechAnalyzer does not resample its input, so convert each capture buffer
    /// to the analyzer's requested format first.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
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
