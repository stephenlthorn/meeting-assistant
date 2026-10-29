import AVFoundation
import CoreGraphics
import XCTest

/// ScreenCaptureKit as the capture logic sees it: what could be captured, and
/// streams that record how they were asked for and can be driven by the test.
final class FakeScreenCaptureBackend: ScreenCaptureBackend, @unchecked Sendable {
    var mainDisplayID: CGDirectDisplayID = 1
    var hasScreenRecordingPermission = true
    var displays = [CaptureDisplay(id: 1)]
    var applications: [CaptureApplication] = []
    var candidatesError: Error?
    var streamStartError: Error?
    private(set) var permissionRequests = 0
    private(set) var streams: [FakeAudioStream] = []

    var latest: FakeAudioStream? { streams.last }

    func requestScreenRecordingPermission() { permissionRequests += 1 }

    func candidates() async throws -> CaptureCandidates {
        if let candidatesError { throw candidatesError }
        return CaptureCandidates(displays: displays, applications: applications)
    }

    func makeStream(display: CaptureDisplay, application: CaptureApplication?,
                    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                    onStop: @escaping @Sendable (Error) -> Void) throws -> AudioStreamHandle {
        let stream = FakeAudioStream(display: display, application: application, onBuffer: onBuffer, onStop: onStop)
        stream.startError = streamStartError
        streams.append(stream)
        return stream
    }
}

final class FakeAudioStream: AudioStreamHandle, @unchecked Sendable {
    let display: CaptureDisplay
    let application: CaptureApplication?
    var startError: Error?
    private(set) var starts = 0
    private(set) var stops = 0
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onStop: @Sendable (Error) -> Void

    init(display: CaptureDisplay, application: CaptureApplication?,
         onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onStop: @escaping @Sendable (Error) -> Void) {
        self.display = display
        self.application = application
        self.onBuffer = onBuffer
        self.onStop = onStop
    }

    func start() async throws {
        starts += 1
        if let startError { throw startError }
    }

    func stop() async { stops += 1 }

    /// The stream delivers audio, as ScreenCaptureKit does on its own thread.
    func hear(_ buffer: AVAudioPCMBuffer = silentBuffer()) { onBuffer(buffer) }

    /// The stream stops by itself.
    func die(_ error: Error) { onStop(error) }
}

/// Collects what a capture reports on the main actor.
@MainActor
final class CaptureReports {
    private(set) var notices: [String?] = []
    private(set) var failures: [CaptureFailure] = []
    private let buffers = BufferCount()

    var buffersHeard: Int { buffers.count }

    init(_ capture: SystemAudioCapturing) {
        capture.onNotice = { [weak self] in self?.notices.append($0) }
        capture.onError = { [weak self] in self?.failures.append($0) }
        let buffers = self.buffers
        capture.onBuffer = { _ in buffers.add() }
    }
}

private final class BufferCount: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    var count: Int { lock.withLock { total } }

    func add() { lock.withLock { total += 1 } }
}
