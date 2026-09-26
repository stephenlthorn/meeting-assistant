import AVFoundation
import XCTest

final class FakeTranscriber: LiveTranscriber {
    let backendName: String
    var onSegment: (@MainActor (TranscriptSegment) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onNotice: (@MainActor (String?) -> Void)?
    var grantsAuthorization: Bool
    private(set) var starts = 0
    private(set) var stops = 0
    private let lock = NSLock()
    private var appendedCount = 0

    init(backendName: String = "on-device", grantsAuthorization: Bool = true) {
        self.backendName = backendName
        self.grantsAuthorization = grantsAuthorization
    }

    var appended: Int { lock.withLock { appendedCount } }

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) { completion(grantsAuthorization) }
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { appendedCount += 1 } }

    @MainActor func emit(_ text: String, utterance: Int = 0, isFinal: Bool = true) {
        onSegment?(TranscriptSegment(utterance: utterance, text: text, isFinal: isFinal))
    }

    @MainActor func fail(_ message: String) { onError?(message) }
    @MainActor func notice(_ message: String?) { onNotice?(message) }
}

final class FakeTranscriberFactory {
    var backendName = "on-device"
    var grantsAuthorization = true
    private(set) var made: [(speaker: Speaker, transcriber: FakeTranscriber)] = []

    func make(_ speaker: Speaker) -> LiveTranscriber {
        let transcriber = FakeTranscriber(backendName: backendName, grantsAuthorization: grantsAuthorization)
        made.append((speaker, transcriber))
        return transcriber
    }

    func latest(_ speaker: Speaker) -> FakeTranscriber? {
        made.last(where: { $0.speaker == speaker })?.transcriber
    }
}

/// Records start/stop calls on the main actor; starts and stops can be held
/// open to reproduce overlapping lifecycles.
final class FakeSystemAudio: SystemAudioCapturing {
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    @MainActor var startError: Error?
    @MainActor var holdsStart = false
    @MainActor var holdsStop = false
    @MainActor private(set) var events: [String] = []
    @MainActor private var heldStart: CheckedContinuation<Void, Never>?
    @MainActor private var heldStop: CheckedContinuation<Void, Never>?

    @MainActor var isCapturing: Bool {
        events.last(where: { $0 == "started" || $0 == "stopped" }) == "started"
    }

    func start() async throws { try await startOnMain() }
    func stop() async { await stopOnMain() }

    @MainActor func releaseStart() {
        heldStart?.resume()
        heldStart = nil
    }

    @MainActor func releaseStop() {
        heldStop?.resume()
        heldStop = nil
    }

    @MainActor private func startOnMain() async throws {
        events.append("start")
        if holdsStart { await withCheckedContinuation { heldStart = $0 } }
        if let startError {
            events.append("failed")
            throw startError
        }
        events.append("started")
    }

    @MainActor private func stopOnMain() async {
        events.append("stop")
        if holdsStop { await withCheckedContinuation { heldStop = $0 } }
        events.append("stopped")
    }
}

final class FakeMicrophone: MicrophoneCapturing {
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var authorized = true
    var startError: Error?
    private(set) var starts = 0
    private(set) var isRunning = false

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) { completion(authorized) }

    func start() throws {
        if let startError { throw startError }
        starts += 1
        isRunning = true
    }

    func stop() { isRunning = false }
}

final class FakeAnswerer: AnswerStreaming {
    private(set) var requests: [AnswerRequest] = []
    private(set) var streams: [AsyncThrowingStream<String, Error>.Continuation] = []

    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        streams.append(continuation)
        return stream
    }
}

final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000)
}

struct TestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func silentBuffer() -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
    buffer.frameLength = 160
    return buffer
}

/// Polls until `condition` holds, failing the test after `timeout`.
@MainActor
func eventually(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("Condition not met within \(timeout)s", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// Gives already-scheduled main-actor work a chance to run.
@MainActor
func settle() async {
    for _ in 0..<5 { try? await Task.sleep(nanoseconds: 10_000_000) }
}
