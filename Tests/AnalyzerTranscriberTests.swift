import AVFoundation
import XCTest

@MainActor
final class AnalyzerTranscriberTests: XCTestCase {
    func testResultsBecomeNumberedUtterances() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }

        h.gate.pipeline.emit("hel", isFinal: false)
        h.gate.pipeline.emit("hello", isFinal: true)
        h.gate.pipeline.emit("next", isFinal: false)

        await eventually { h.segments.count == 3 }
        XCTAssertEqual(h.segments, [
            TranscriptSegment(utterance: 0, text: "hel", isFinal: false),
            TranscriptSegment(utterance: 0, text: "hello", isFinal: true),
            TranscriptSegment(utterance: 1, text: "next", isFinal: false),
        ])
    }

    func testAudioIsConvertedToThePipelinesFormat() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }
        await settle()

        for _ in 0..<10 { h.transcriber.append(tone(amplitude: 0.2, sampleRate: 48_000)) }

        let fed = h.gate.pipeline.fed
        XCTAssertEqual(Set(fed.map(\.format.sampleRate)), [16_000])
        let frames = fed.map(\.frameLength).reduce(0, +)
        XCTAssertLessThanOrEqual(frames, 16_000)
        XCTAssertGreaterThanOrEqual(frames, 16_000 - 1_600,
                                    "the resampler may hold back up to one buffer, but must not drop audio")
    }

    func testAudioBeforeThePipelineIsReadyIsDropped() async {
        let h = makeHarness()
        h.gate.holds = true
        h.transcriber.start()
        await eventually { h.gate.waiting }

        h.transcriber.append(tone(amplitude: 0.2))
        h.gate.release()
        await eventually { h.gate.handedOut }

        XCTAssertTrue(h.gate.pipeline.fed.isEmpty)
    }

    func testStoppingDuringSetupShutsThePipelineDownWhenItArrives() async {
        let h = makeHarness()
        h.gate.holds = true
        h.transcriber.start()
        await eventually { h.gate.waiting }

        h.transcriber.stop()
        h.gate.release()

        await eventually { h.gate.pipeline.finished }
        h.transcriber.append(tone(amplitude: 0.2))
        h.gate.pipeline.emit("late", isFinal: true)
        await settle()
        XCTAssertTrue(h.gate.pipeline.fed.isEmpty)
        XCTAssertTrue(h.segments.isEmpty)
    }

    func testStoppingFinishesThePipeline() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }
        await settle()

        h.transcriber.stop()

        await eventually { h.gate.pipeline.finished }
    }

    func testSetupProgressShowsAsANotice() async {
        let h = makeHarness()
        h.gate.progress = ["Downloading the on-device speech model…", nil]

        h.transcriber.start()

        await eventually { h.notices.count == 2 }
        XCTAssertEqual(h.notices, ["Downloading the on-device speech model…", nil])
    }

    func testASetupFailureIsReported() async {
        let h = makeHarness()
        h.gate.error = TestFailure(message: "No model for this language")

        h.transcriber.start()

        await eventually { !h.errors.isEmpty }
        XCTAssertEqual(h.errors, ["SpeechAnalyzer setup failed: No model for this language"])
    }

    func testASetupFailureAfterStopIsNotReported() async {
        let h = makeHarness()
        h.gate.holds = true
        h.gate.error = TestFailure(message: "Cancelled")
        h.transcriber.start()
        await eventually { h.gate.waiting }

        h.transcriber.stop()
        h.gate.release()

        await settle()
        XCTAssertTrue(h.errors.isEmpty)
    }

    func testAStreamErrorWhileRunningIsReported() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }

        h.gate.pipeline.fail(TestFailure(message: "Model crashed"))

        await eventually { !h.errors.isEmpty }
        XCTAssertEqual(h.errors, ["Transcription stream error: Model crashed"])
    }

    // MARK: - Harness

    private final class Harness {
        let gate = PipelineGate()
        let transcriber: AnalyzerTranscriber
        var segments: [TranscriptSegment] = []
        var errors: [String] = []
        var notices: [String?] = []

        init() {
            transcriber = AnalyzerTranscriber(makePipeline: gate.make)
        }
    }

    private func makeHarness() -> Harness {
        let h = Harness()
        h.transcriber.onSegment = { [unowned h] in h.segments.append($0) }
        h.transcriber.onError = { [unowned h] in h.errors.append($0) }
        h.transcriber.onNotice = { [unowned h] in h.notices.append($0) }
        return h
    }
}

final class FakeAnalyzerPipeline: AnalyzerPipeline, @unchecked Sendable {
    let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let results: AsyncThrowingStream<(text: String, isFinal: Bool), Error>
    private let continuation: AsyncThrowingStream<(text: String, isFinal: Bool), Error>.Continuation
    private let lock = NSLock()
    private var fedBuffers: [AVAudioPCMBuffer] = []
    private var isFinished = false

    init() {
        (results, continuation) = AsyncThrowingStream.makeStream()
    }

    var fed: [AVAudioPCMBuffer] { lock.withLock { fedBuffers } }
    var finished: Bool { lock.withLock { isFinished } }

    func feed(_ buffer: AVAudioPCMBuffer) { lock.withLock { fedBuffers.append(buffer) } }

    func finish() async {
        lock.withLock { isFinished = true }
        continuation.finish()
    }

    func emit(_ text: String, isFinal: Bool) { continuation.yield((text, isFinal)) }
    func fail(_ error: Error) { continuation.finish(throwing: error) }
}

/// Stands in for building the SpeechAnalyzer pipeline, which can take minutes
/// on first use while the model downloads.
final class PipelineGate: @unchecked Sendable {
    let pipeline = FakeAnalyzerPipeline()
    var holds = false
    var error: Error?
    var progress: [String?] = []
    private let lock = NSLock()
    private var held: CheckedContinuation<Void, Never>?
    private var isWaiting = false
    private var didHandOut = false

    var waiting: Bool { lock.withLock { isWaiting } }
    var handedOut: Bool { lock.withLock { didHandOut } }

    func make(onProgress: @escaping (String?) -> Void) async throws -> AnalyzerPipeline {
        progress.forEach(onProgress)
        if holds {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    held = continuation
                    isWaiting = true
                }
            }
        }
        if let error { throw error }
        lock.withLock { didHandOut = true }
        return pipeline
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }
}
