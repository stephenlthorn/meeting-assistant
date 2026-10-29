import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A display that can be captured.
struct CaptureDisplay: Equatable, Sendable {
    let id: CGDirectDisplayID
}

/// A running app whose audio can be captured on its own.
struct CaptureApplication: Equatable, Sendable {
    let bundleID: String
    let name: String
}

/// What could be captured right now.
struct CaptureCandidates: Sendable {
    var displays: [CaptureDisplay]
    var applications: [CaptureApplication]
}

/// One system-audio stream. It reports through the closures it was made with;
/// the owner decides which stream is current and ignores the rest.
protocol AudioStreamHandle: AnyObject {
    func start() async throws
    func stop() async
}

/// ScreenCaptureKit and the screen-recording permission, behind a protocol so
/// the choice of display and app, the notices and the error handling can be
/// tested without a screen or a permission prompt.
protocol ScreenCaptureBackend: AnyObject {
    var mainDisplayID: CGDirectDisplayID { get }
    var hasScreenRecordingPermission: Bool { get }
    func requestScreenRecordingPermission()
    func candidates() async throws -> CaptureCandidates
    /// Builds a stream of `display`'s audio, limited to `application` when one is
    /// given. `onBuffer` is called on a capture thread; `onStop` when the stream
    /// stops by itself. Nothing is captured until `start()`.
    func makeStream(display: CaptureDisplay, application: CaptureApplication?,
                    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                    onStop: @escaping @Sendable (Error) -> Void) throws -> AudioStreamHandle
}

/// The real thing. `makeStream` needs the objects `candidates()` found, so it
/// keeps the latest result; a Start always asks first.
final class ScreenCaptureKitBackend: ScreenCaptureBackend {
    private let lock = NSLock()
    private var content: SCShareableContent? // guarded by `lock`

    var mainDisplayID: CGDirectDisplayID { CGMainDisplayID() }

    var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Windows that are minimized or on another Space still count: a call app
    /// in the background is still the app to listen to.
    func candidates() async throws -> CaptureCandidates {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        lock.withLock { self.content = content }
        return CaptureCandidates(
            displays: content.displays.map { CaptureDisplay(id: $0.displayID) },
            applications: content.applications.map {
                CaptureApplication(bundleID: $0.bundleIdentifier, name: $0.applicationName)
            })
    }

    func makeStream(display: CaptureDisplay, application: CaptureApplication?,
                    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                    onStop: @escaping @Sendable (Error) -> Void) throws -> AudioStreamHandle {
        guard let content = lock.withLock({ self.content }),
              let screen = content.displays.first(where: { $0.displayID == display.id }) else {
            throw SystemAudioError.noDisplay
        }
        let filter: SCContentFilter
        if let application, let running = content.applications.first(where: { $0.bundleIdentifier == application.bundleID }) {
            filter = SCContentFilter(display: screen, including: [running], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: screen, excludingApplications: [], exceptingWindows: [])
        }
        return try ScreenCaptureKitStream(filter: filter, onBuffer: onBuffer, onStop: onStop)
    }
}

/// One SCStream. Audio and errors are only passed on while it is the live
/// stream: after `stop()`, or once it has reported its own death, it says nothing.
final class ScreenCaptureKitStream: NSObject, AudioStreamHandle, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var stream: SCStream? // guarded by `lock`; cleared when the stream ends, which also ends any retain cycle
    private let audioQueue = DispatchQueue(label: "meetingassistant.audio.capture")
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onStop: @Sendable (Error) -> Void

    init(filter: SCContentFilter, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         onStop: @escaping @Sendable (Error) -> Void) throws {
        self.onBuffer = onBuffer
        self.onStop = onStop
        super.init()
        let stream = SCStream(filter: filter, configuration: SystemAudioCapture.makeConfiguration(), delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        lock.withLock { self.stream = stream }
    }

    func start() async throws {
        guard let stream = lock.withLock({ self.stream }) else { throw CancellationError() }
        do {
            try await stream.startCapture()
        } catch {
            lock.withLock { if self.stream === stream { self.stream = nil } }
            throw error
        }
    }

    func stop() async {
        let stream = lock.withLock { () -> SCStream? in
            defer { self.stream = nil }
            return self.stream
        }
        try? await stream?.stopCapture()
    }

    private func isLive(_ stream: SCStream) -> Bool {
        lock.withLock { self.stream === stream }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio,
              isLive(stream),
              sampleBuffer.isValid,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let pcm = SystemAudioCapture.makePCMBuffer(from: sampleBuffer) else { return }
        onBuffer(AudioMath.monoMix(pcm) ?? pcm)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let wasLive = lock.withLock { () -> Bool in
            guard self.stream === stream else { return false }
            self.stream = nil
            return true
        }
        guard wasLive else { return }
        onStop(error)
    }
}
