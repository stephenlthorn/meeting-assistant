import AVFoundation
import Speech
import XCTest

@MainActor
final class LegacySpeechTranscriberTests: XCTestCase {
    func testEachRecognitionRequestIsItsOwnUtterance() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.engine.sessions[0].result("hello", isFinal: false)
        h.clock.now += 46
        h.transcriber.append(tone(amplitude: 0.1))
        h.flush()
        h.engine.sessions[0].result("hello there", isFinal: true)
        h.engine.sessions[1].result("next", isFinal: false)
        h.flush()

        await eventually { h.segments.count == 3 }
        XCTAssertEqual(h.segments[0].text, "hello")
        XCTAssertEqual(h.segments[1], TranscriptSegment(utterance: h.segments[0].utterance, text: "hello there", isFinal: true))
        XCTAssertNotEqual(h.segments[2].utterance, h.segments[0].utterance)
    }

    func testALateErrorFromAFinishedRequestDoesNotRestartTheCurrentOne() {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()
        h.clock.now += 46
        h.transcriber.append(tone(amplitude: 0.1))
        h.flush()

        h.engine.sessions[0].fail()
        h.flush()

        XCTAssertEqual(h.engine.sessions.count, 2)
        XCTAssertFalse(h.engine.sessions[1].finished)
    }

    func testAnErrorAfterSpeechStartsTheNextRequestRightAway() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.engine.sessions[0].result("hi", isFinal: false)
        h.engine.sessions[0].fail()
        h.flush()

        XCTAssertEqual(h.engine.sessions.count, 2)
        XCTAssertTrue(h.scheduler.delays.isEmpty)
        await settle()
        XCTAssertTrue(h.errors.isEmpty)
    }

    func testRequestsThatFailImmediatelyBackOffAndThenReportTheProblem() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.engine.sessions[0].fail(TestFailure(message: "Siri and Dictation are disabled"))
        h.flush()
        XCTAssertEqual(h.engine.sessions.count, 1)
        XCTAssertEqual(h.scheduler.delays, [0.5])

        h.scheduler.fireAll()
        h.flush()
        h.engine.sessions[1].fail(TestFailure(message: "Siri and Dictation are disabled"))
        h.flush()
        XCTAssertEqual(h.scheduler.delays, [1.0])

        h.scheduler.fireAll()
        h.flush()
        h.engine.sessions[2].fail(TestFailure(message: "Siri and Dictation are disabled"))
        h.flush()
        XCTAssertEqual(h.scheduler.delays, [2.0])

        await eventually { !h.errors.isEmpty }
        XCTAssertEqual(h.errors, ["Speech recognition keeps failing: Siri and Dictation are disabled"])
    }

    func testAudioIsDroppedWhileWaitingToRetry() {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()
        h.engine.sessions[0].fail()
        h.flush()

        h.transcriber.append(tone(amplitude: 0.1))
        h.flush()

        XCTAssertEqual(h.engine.sessions.count, 1)
        XCTAssertEqual(h.engine.sessions[0].appended, 0)
    }

    func testAPauseAfterSpeechEndsTheRequestSoItsTextIsFinal() {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        for (time, amplitude) in [(0.5, 0.1), (1.0, 0.1), (1.5, 0.0001)] as [(TimeInterval, Float)] {
            h.clock.now = h.startTime + time
            h.transcriber.append(tone(amplitude: amplitude))
        }
        h.flush()
        XCTAssertEqual(h.engine.sessions.count, 1)

        h.clock.now = h.startTime + 2.0
        h.transcriber.append(tone(amplitude: 0.0001))
        h.flush()

        XCTAssertTrue(h.engine.sessions[0].finished)
        XCTAssertEqual(h.engine.sessions.count, 2)
    }

    func testSilenceWithoutSpeechKeepsTheRequestOpen() {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        for second in 1...10 {
            h.clock.now = h.startTime + TimeInterval(second)
            h.transcriber.append(tone(amplitude: 0.0001))
        }
        h.flush()

        XCTAssertEqual(h.engine.sessions.count, 1)
    }

    func testRequestsRotateAtTheLengthLimitEvenWithoutAPause() {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        for second in 1...44 {
            h.clock.now = h.startTime + TimeInterval(second)
            h.transcriber.append(tone(amplitude: 0.1))
        }
        h.flush()
        XCTAssertEqual(h.engine.sessions.count, 1)

        h.clock.now = h.startTime + 45
        h.transcriber.append(tone(amplitude: 0.1))
        h.flush()
        XCTAssertEqual(h.engine.sessions.count, 2)
    }

    func testStoppingLetsTheLastRequestFinishAndDropsLaterAudio() {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.transcriber.stop()
        h.transcriber.append(tone(amplitude: 0.1))
        h.flush()

        XCTAssertTrue(h.engine.sessions[0].finished)
        XCTAssertFalse(h.engine.sessions[0].cancelled)
        XCTAssertEqual(h.engine.sessions[0].appended, 0)
    }

    func testAnUnavailableRecognizerReportsAnError() async {
        let h = makeHarness()
        h.engine.isAvailable = false

        h.transcriber.start()
        h.flush()

        await eventually { !h.errors.isEmpty }
        XCTAssertEqual(h.errors, ["Speech recognition isn't available for this language right now."])
        XCTAssertTrue(h.engine.sessions.isEmpty)
    }

    func testServerRecognitionIsAnnounced() async {
        let h = makeHarness()
        h.engine.supportsOnDeviceRecognition = false

        h.transcriber.start()
        h.flush()

        await eventually { !h.notices.isEmpty }
        XCTAssertEqual(h.notices, ["On-device speech isn't available for this language, so audio goes to Apple's servers."])
    }

    func testRecognitionRequestsReportPartialsWithPunctuation() {
        let onDevice = AppleSpeechEngine.makeRequest(onDevice: true)
        XCTAssertTrue(onDevice.shouldReportPartialResults)
        XCTAssertTrue(onDevice.addsPunctuation)
        XCTAssertTrue(onDevice.requiresOnDeviceRecognition)

        XCTAssertFalse(AppleSpeechEngine.makeRequest(onDevice: false).requiresOnDeviceRecognition)
    }

    // MARK: - Harness

    private final class Harness {
        let transcriber: LegacySpeechTranscriber
        let engine: FakeSpeechEngine
        let scheduler: ManualScheduler
        let clock: TestClock
        let queue: DispatchQueue
        let startTime: Date
        var segments: [TranscriptSegment] = []
        var errors: [String] = []
        var notices: [String] = []

        init() {
            engine = FakeSpeechEngine()
            scheduler = ManualScheduler()
            clock = TestClock()
            startTime = clock.now
            queue = DispatchQueue(label: "LegacySpeechTranscriberTests")
            transcriber = LegacySpeechTranscriber(engine: engine, queue: queue, now: { [clock] in clock.now },
                                                  schedule: scheduler.schedule)
        }

        func flush() { queue.sync {} }
    }

    private func makeHarness() -> Harness {
        let h = Harness()
        h.transcriber.onSegment = { [unowned h] in h.segments.append($0) }
        h.transcriber.onError = { [unowned h] in h.errors.append($0) }
        h.transcriber.onNotice = { [unowned h] in if let notice = $0 { h.notices.append(notice) } }
        return h
    }
}

final class FakeSpeechEngine: SpeechRecognitionEngine {
    var isAvailable = true
    var supportsOnDeviceRecognition = true
    var authorized = true
    private(set) var sessions: [FakeRecognitionSession] = []

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) { completion(authorized) }

    func startSession(onResult: @escaping (String, Bool) -> Void,
                      onError: @escaping (Error) -> Void) -> SpeechRecognitionSession {
        let session = FakeRecognitionSession(onResult: onResult, onError: onError)
        sessions.append(session)
        return session
    }
}

final class FakeRecognitionSession: SpeechRecognitionSession {
    private let onResult: (String, Bool) -> Void
    private let onError: (Error) -> Void
    private(set) var appended = 0
    private(set) var finished = false
    private(set) var cancelled = false

    init(onResult: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        self.onResult = onResult
        self.onError = onError
    }

    func append(_ buffer: AVAudioPCMBuffer) { appended += 1 }
    func finish() { finished = true }
    func cancel() { cancelled = true }

    func result(_ text: String, isFinal: Bool) { onResult(text, isFinal) }
    func fail(_ error: Error = TestFailure(message: "No speech detected")) { onError(error) }
}

/// A 100 ms mono tone at a constant amplitude.
func tone(amplitude: Float, sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    let frames = AVAudioFrameCount(sampleRate / 10)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
        for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = amplitude }
    }
    return buffer
}
