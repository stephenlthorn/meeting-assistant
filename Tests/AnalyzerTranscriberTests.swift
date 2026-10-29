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

        await eventually { h.gate.pipeline.cancelled }
        h.transcriber.append(tone(amplitude: 0.2))
        h.gate.pipeline.emit("late", isFinal: true)
        await settle()
        XCTAssertTrue(h.gate.pipeline.fed.isEmpty)
        XCTAssertTrue(h.segments.isEmpty)
    }

    func testStoppingLetsThePipelineFinishWhatItHeard() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }
        h.gate.pipeline.emit("We should ship in", isFinal: false)
        await eventually { h.segments.count == 1 }

        h.transcriber.stop()
        await eventually { h.gate.pipeline.finished }
        h.gate.pipeline.emit("We should ship in May.", isFinal: true)
        h.gate.pipeline.endResults()

        await eventually { h.segments.count == 2 }
        XCTAssertEqual(h.segments.last, TranscriptSegment(utterance: 0, text: "We should ship in May.", isFinal: true))
        await settle()
        XCTAssertEqual(h.gate.makes, 1, "a pipeline that ended because we stopped is not rebuilt")
        XCTAssertTrue(h.scheduler.delays.contains(AnalyzerTranscriber.defaultDrainTimeout))
        XCTAssertTrue(h.errors.isEmpty)
    }

    func testAPipelineThatIsTakingTooLongToFinishIsShutDown() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }
        h.transcriber.stop()
        await eventually { h.gate.pipeline.finished }

        h.scheduler.fireAll()

        await eventually { h.gate.pipeline.cancelled }
    }

    func testAudioIsNotFedWhileDraining() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }
        await settle()
        h.transcriber.stop()

        h.transcriber.append(tone(amplitude: 0.2))

        XCTAssertTrue(h.gate.pipeline.fed.isEmpty)
    }

    func testStartingAgainLeavesTheOldPipelinesResultsBehind() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }
        let old = h.gate.pipeline
        h.transcriber.stop()
        await eventually { old.finished }

        h.transcriber.start()
        await eventually { h.gate.pipelines.count == 2 }
        old.emit("old words", isFinal: true)
        h.gate.pipeline.emit("new words", isFinal: false)

        await eventually { !h.segments.isEmpty }
        await settle()
        XCTAssertEqual(h.segments, [TranscriptSegment(utterance: 0, text: "new words", isFinal: false)])
    }

    func testStoppingDuringSetupCancelsTheSetupInsteadOfFinishingTheDownload() async {
        let h = makeHarness()
        h.gate.holds = true
        h.transcriber.start()
        await eventually { h.gate.waiting }

        h.transcriber.stop()
        h.gate.release()

        await eventually { h.gate.sawCancellation }
    }

    func testStoppingWhileADrainIsUnderwayDoesNotCancelTheResults() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }
        await settle()

        h.transcriber.stop()
        await eventually { h.gate.pipeline.finished }
        h.gate.pipeline.emit("last words", isFinal: true)

        await eventually { h.segments.count == 1 }
    }

    func testSetupProgressShowsAsANotice() async {
        let h = makeHarness()
        h.gate.progress = ["Downloading the on-device speech model…", nil]

        h.transcriber.start()

        await eventually { h.notices.count == 2 }
        XCTAssertEqual(h.notices, ["Downloading the on-device speech model…", nil])
    }

    func testASetupFailureIsRetriedWithBackoffAndReportedOnTheThirdTry() async {
        let h = makeHarness()
        h.gate.error = TestFailure(message: "No model for this language")

        h.transcriber.start()
        await eventually { h.gate.makes == 1 && h.scheduler.delays == [1] }
        h.scheduler.fireAll()
        await eventually { h.gate.makes == 2 && h.scheduler.delays == [2] }
        XCTAssertTrue(h.errors.isEmpty)
        h.scheduler.fireAll()
        await eventually { h.gate.makes == 3 && h.scheduler.delays == [4] }

        await eventually { !h.errors.isEmpty }
        XCTAssertEqual(h.errors, ["SpeechAnalyzer setup failed: No model for this language"])
    }

    func testRetriesKeepGoingQuietlyAfterTheReportAndRecoverWhenSetupWorks() async {
        let h = makeHarness()
        h.gate.error = TestFailure(message: "Offline")
        h.transcriber.start()
        for attempt in 1...4 {
            await eventually { h.gate.makes == attempt && !h.scheduler.delays.isEmpty }
            if attempt == 4 { h.gate.error = nil }
            h.scheduler.fireAll()
        }

        await eventually { h.gate.makes == 5 && h.gate.handedOut }
        XCTAssertEqual(h.errors, ["SpeechAnalyzer setup failed: Offline"])
        h.gate.pipeline.emit("back", isFinal: false)
        await eventually { h.segments.count == 1 }
    }

    func testALanguageWithNoModelIsReportedAtOnceAndNotRetried() async {
        let h = makeHarness()
        h.gate.error = AnalyzerSetupError.unsupportedLocale

        h.transcriber.start()

        await eventually { !h.errors.isEmpty }
        await settle()
        XCTAssertEqual(h.errors, ["SpeechAnalyzer setup failed: SpeechAnalyzer has no model for this language."])
        XCTAssertTrue(h.scheduler.delays.isEmpty)
        XCTAssertEqual(h.gate.makes, 1)
    }

    // MARK: - Fatal failures (M1)

    func testALanguageWithNoModelIsFatal() async {
        let h = makeHarness()
        h.gate.error = AnalyzerSetupError.unsupportedLocale

        h.transcriber.start()

        await eventually { !h.fatals.isEmpty }
        XCTAssertEqual(h.fatals, ["SpeechAnalyzer setup failed: SpeechAnalyzer has no model for this language."])
    }

    func testSetupTroubleThatIsStillBeingRetriedIsNotFatal() async {
        let h = makeHarness()
        h.gate.error = TestFailure(message: "Offline")

        h.transcriber.start()
        let attempts = AnalyzerTranscriber.failuresBeforeReporting
        for attempt in 1...attempts {
            await eventually { h.gate.makes == attempt && !h.scheduler.delays.isEmpty }
            if attempt < attempts { h.scheduler.fireAll() }
        }

        await eventually { !h.errors.isEmpty }
        XCTAssertEqual(h.fatals, [], "it keeps retrying, so the side is not dead")
    }

    func testASetupFailureAfterStopIsNotReportedOrRetried() async {
        let h = makeHarness()
        h.gate.holds = true
        h.gate.error = TestFailure(message: "Cancelled")
        h.transcriber.start()
        await eventually { h.gate.waiting }

        h.transcriber.stop()
        h.gate.release()

        await settle()
        XCTAssertTrue(h.errors.isEmpty)
        XCTAssertTrue(h.scheduler.delays.isEmpty)
    }

    func testAStreamErrorRebuildsThePipelineAndKeepsNumberingUtterances() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }
        h.gate.pipeline.emit("one", isFinal: true)
        await eventually { h.segments.count == 1 }

        h.gate.pipeline.fail(TestFailure(message: "Model crashed"))
        await eventually { !h.scheduler.delays.isEmpty }
        h.scheduler.fireAll()
        await eventually { h.gate.pipelines.count == 2 }
        h.gate.pipeline.emit("two", isFinal: false)

        await eventually { h.segments.count == 2 }
        XCTAssertEqual(h.segments, [
            TranscriptSegment(utterance: 0, text: "one", isFinal: true),
            TranscriptSegment(utterance: 1, text: "two", isFinal: false),
        ])
        XCTAssertTrue(h.errors.isEmpty)
        XCTAssertTrue(h.gate.pipelines[0].cancelled, "the dead pipeline is released")
    }

    func testAudioGoesToTheRebuiltPipeline() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }
        h.gate.pipeline.fail(TestFailure(message: "Model crashed"))
        await eventually { !h.scheduler.delays.isEmpty }
        h.scheduler.fireAll()
        await eventually { h.gate.pipelines.count == 2 }
        await settle()

        h.transcriber.append(tone(amplitude: 0.2))

        XCTAssertEqual(h.gate.pipelines[0].fed.count, 0)
        XCTAssertEqual(h.gate.pipelines[1].fed.count, 1)
    }

    func testAStreamThatEndsCleanlyIsRebuiltToo() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }

        h.gate.pipeline.endResults()
        await eventually { !h.scheduler.delays.isEmpty }
        h.scheduler.fireAll()

        await eventually { h.gate.makes == 2 }
    }

    func testRepeatedStreamFailuresAreReportedOnceOnTheThird() async {
        let h = makeHarness()
        h.transcriber.start()
        for attempt in 1...3 {
            await eventually { h.gate.pipelines.count == attempt }
            await settle()
            h.gate.pipeline.fail(TestFailure(message: "Model crashed"))
            await eventually { !h.scheduler.delays.isEmpty }
            await settle()
            XCTAssertEqual(h.errors.count, attempt == 3 ? 1 : 0)
            h.scheduler.fireAll()
        }

        await eventually { h.gate.makes == 4 }
        XCTAssertEqual(h.errors, ["Transcription stream error: Model crashed"])
    }

    func testAPipelineThatProducedResultsStartsTheFailureCountOver() async {
        let h = makeHarness()
        h.transcriber.start()
        for attempt in 1...4 {
            await eventually { h.gate.pipelines.count == attempt }
            h.gate.pipeline.emit("words", isFinal: false)
            await eventually { h.segments.count == attempt }
            h.gate.pipeline.fail(TestFailure(message: "Model crashed"))
            await eventually { !h.scheduler.delays.isEmpty }
            h.scheduler.fireAll()
        }

        await settle()
        XCTAssertTrue(h.errors.isEmpty)
    }

    func testStoppingDuringBackoffCancelsTheRebuild() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }
        h.gate.pipeline.fail(TestFailure(message: "Model crashed"))
        await eventually { !h.scheduler.delays.isEmpty }

        h.transcriber.stop()
        h.scheduler.fireAll()

        await settle()
        XCTAssertEqual(h.gate.makes, 1)
    }

    // MARK: - Falling behind

    func testAudioThatCannotBeKeptUpWithIsReportedOnce() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }
        await settle()
        h.gate.pipeline.dropsAudio = true

        for _ in 0..<5 { h.transcriber.append(tone(amplitude: 0.2)) }

        await eventually { !h.errors.isEmpty }
        await settle()
        XCTAssertEqual(h.errors, ["Speech analysis can't keep up, so some audio is being skipped."])
    }

    func testKeepingUpIsNeverReported() async {
        let h = makeHarness()
        h.transcriber.start()
        await eventually { h.gate.handedOut }
        await settle()

        for _ in 0..<5 { h.transcriber.append(tone(amplitude: 0.2)) }

        await settle()
        XCTAssertTrue(h.errors.isEmpty)
    }

    // MARK: - Notices (AUD-11)

    func testADownloadThatFailsClearsItsNotice() async {
        let h = makeHarness()
        h.gate.progress = ["Downloading the on-device speech model…"]
        h.gate.error = TestFailure(message: "Offline")

        h.transcriber.start()

        await eventually { h.notices.count == 2 }
        XCTAssertEqual(h.notices, ["Downloading the on-device speech model…", nil])
    }

    // MARK: - Harness

    private final class Harness {
        let gate = PipelineGate()
        let transcriber: AnalyzerTranscriber
        var segments: [TranscriptSegment] = []
        var errors: [String] = []
        var fatals: [String] = []
        var notices: [String?] = []

        let scheduler = ThreadSafeScheduler()

        init() {
            transcriber = AnalyzerTranscriber(makePipeline: gate.make, schedule: scheduler.schedule)
        }
    }

    private func makeHarness() -> Harness {
        let h = Harness()
        h.transcriber.onSegment = { [weak h] in h?.segments.append($0) }
        h.transcriber.onError = { [weak h] in h?.errors.append($0) }
        h.transcriber.onFatal = { [weak h] in h?.fatals.append($0) }
        h.transcriber.onNotice = { [weak h] in h?.notices.append($0) }
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
    private var isCancelled = false
    private var isDropping = false

    init() {
        (results, continuation) = AsyncThrowingStream.makeStream()
    }

    var fed: [AVAudioPCMBuffer] { lock.withLock { fedBuffers } }
    /// `finish()` was called: the input ended and the analyzer may still report.
    var finished: Bool { lock.withLock { isFinished } }
    /// `cancel()` was called: the pipeline was shut down on the spot.
    var cancelled: Bool { lock.withLock { isCancelled } }
    /// Makes `feed` say the audio could not be queued.
    var dropsAudio: Bool {
        get { lock.withLock { isDropping } }
        set { lock.withLock { isDropping = newValue } }
    }

    func feed(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.withLock {
            fedBuffers.append(buffer)
            return !isDropping
        }
    }

    func finish() async {
        lock.withLock { isFinished = true }
    }

    func cancel() async {
        lock.withLock { isCancelled = true }
        continuation.finish()
    }

    func emit(_ text: String, isFinal: Bool) { continuation.yield((text, isFinal)) }
    func fail(_ error: Error) { continuation.finish(throwing: error) }
    func endResults() { continuation.finish() }
}

/// Stands in for building the SpeechAnalyzer pipeline, which can take minutes
/// on first use while the model downloads. Each build hands out a new pipeline.
final class PipelineGate: @unchecked Sendable {
    var holds = false
    var error: Error?
    var progress: [String?] = []
    private let lock = NSLock()
    private var built: [FakeAnalyzerPipeline] = [FakeAnalyzerPipeline()]
    private var made = 0
    private var held: CheckedContinuation<Void, Never>?
    private var isWaiting = false
    private var didHandOut = false
    private var cancelledDuringSetup = false

    var waiting: Bool { lock.withLock { isWaiting } }
    /// Whether the build task was cancelled while it waited.
    var sawCancellation: Bool { lock.withLock { cancelledDuringSetup } }
    var handedOut: Bool { lock.withLock { didHandOut } }
    /// How many times a pipeline was asked for.
    var makes: Int { lock.withLock { made } }
    /// The pipeline most recently handed out, or the one about to be.
    var pipeline: FakeAnalyzerPipeline { lock.withLock { built[max(0, handedOutCount - 1)] } }
    var pipelines: [FakeAnalyzerPipeline] { lock.withLock { Array(built.prefix(handedOutCount)) } }

    private var handedOutCount = 0

    func make(onProgress: @escaping (String?) -> Void) async throws -> AnalyzerPipeline {
        lock.withLock { made += 1 }
        progress.forEach(onProgress)
        if holds {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    held = continuation
                    isWaiting = true
                }
            }
        }
        if Task.isCancelled { lock.withLock { cancelledDuringSetup = true } }
        if let error { throw error }
        return lock.withLock {
            let pipeline = built[handedOutCount]
            handedOutCount += 1
            built.append(FakeAnalyzerPipeline())
            didHandOut = true
            return pipeline
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }
}
