import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures the Mac's system audio output (what your speakers/headphones play,
/// i.e. the other people on the call) using ScreenCaptureKit. No virtual audio
/// device required on macOS 13+. Delivers mono PCM buffers to `onBuffer`,
/// requested at 16 kHz since that is all speech recognition needs.
///
/// It listens to every app, or only to the app named at `start` when that app
/// is running: music, notification sounds and a video in another tab then stay
/// out of "Them". When the app is not running it falls back to every app and
/// says so through `onNotice`, since silence would look like a broken capture.
///
/// Permission: first `start()` triggers the system "Screen Recording" prompt
/// (ScreenCaptureKit is gated by that TCC permission even for audio-only use).
///
/// Audio and errors are only accepted from the current stream: stopping or
/// replacing it makes the old one irrelevant, so a late error from a stream
/// that was already stopped cannot be mistaken for a failure of its successor.
/// ScreenCaptureKit itself is behind `ScreenCaptureBackend`.
final class SystemAudioCapture: SystemAudioCapturing {
    private let backend: ScreenCaptureBackend
    private let lock = NSLock()
    private var generation = 0 // guarded by `lock`
    private var current: (id: Int, stream: AudioStreamHandle)? // guarded by `lock`

    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onError: (@MainActor (CaptureFailure) -> Void)?
    var onNotice: (@MainActor (String?) -> Void)?

    init(backend: ScreenCaptureBackend = ScreenCaptureKitBackend()) {
        self.backend = backend
    }

    func start(application bundleID: String?) async throws {
        do {
            try await startStream(application: bundleID)
        } catch let error as SystemAudioError {
            throw error
        } catch {
            guard backend.hasScreenRecordingPermission else {
                backend.requestScreenRecordingPermission()
                throw SystemAudioError.permissionDenied
            }
            throw error
        }
    }

    private func startStream(application bundleID: String?) async throws {
        await stop()
        let candidates = try await backend.candidates()
        let plan = try Self.plan(candidates, mainDisplayID: backend.mainDisplayID, application: bundleID)
        let id = lock.withLock { () -> Int in
            generation += 1
            return generation
        }
        let stream = try backend.makeStream(
            display: plan.display, application: plan.application,
            onBuffer: { [weak self] buffer in self?.deliver(buffer, from: id) },
            onStop: { [weak self] error in self?.stopped(by: error, stream: id) })
        lock.withLock { current = (id, stream) }
        do {
            try await stream.start()
        } catch {
            lock.withLock { if current?.id == id { current = nil } }
            throw error
        }
        let onNotice = self.onNotice
        deliverOnMain { onNotice?(plan.notice) }
    }

    func stop() async {
        let stream = lock.withLock { () -> AudioStreamHandle? in
            defer { current = nil }
            return current?.stream
        }
        await stream?.stop()
    }

    private func isCurrent(_ id: Int) -> Bool {
        lock.withLock { current?.id == id }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer, from id: Int) {
        guard isCurrent(id) else { return }
        onBuffer?(buffer)
    }

    private func stopped(by error: Error, stream id: Int) {
        let wasCurrent = lock.withLock { () -> Bool in
            guard current?.id == id else { return false }
            current = nil
            return true
        }
        guard wasCurrent else { return }
        let onError = self.onError
        let failure = CaptureFailure(message: error.localizedDescription, isRetryable: Self.isRetryable(error))
        deliverOnMain { onError?(failure) }
    }

    // MARK: - What to capture

    struct Plan: Equatable {
        let display: CaptureDisplay
        let application: CaptureApplication?
        /// Set when what is captured is not what was asked for.
        let notice: String?
    }

    static func plan(_ candidates: CaptureCandidates, mainDisplayID: CGDirectDisplayID,
                     application bundleID: String?) throws -> Plan {
        guard let display = preferredDisplay(candidates.displays, mainDisplayID: mainDisplayID, id: \.id) else {
            throw SystemAudioError.noDisplay
        }
        guard let bundleID else { return Plan(display: display, application: nil, notice: nil) }
        guard let application = candidates.applications.first(where: { $0.bundleID == bundleID }) else {
            let name = MeetingApps.name(for: bundleID) ?? bundleID
            return Plan(display: display, application: nil, notice: "\(name) is not running, listening to all apps")
        }
        return Plan(display: display, application: application, notice: nil)
    }

    /// The system audio is the same whichever display is captured; the main one
    /// is the least likely to be unplugged or put to sleep mid-call.
    static func preferredDisplay<Display>(_ displays: [Display], mainDisplayID: CGDirectDisplayID,
                                          id: KeyPath<Display, CGDirectDisplayID>) -> Display? {
        displays.first { $0[keyPath: id] == mainDisplayID } ?? displays.first
    }

    /// Stopping on purpose, or the system's permission being withdrawn, will not
    /// be undone by starting again (which could even re-prompt the user).
    static func isRetryable(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == SCStreamErrorDomain else { return true }
        switch SCStreamError.Code(rawValue: error.code) {
        case .userStopped, .userDeclined, .missingEntitlements: return false
        default: return true
        }
    }

    /// Whole-display audio, mono at 16 kHz, without our own sounds. SCStream
    /// requires video too, so it is 2x2 pixels at most once a second and never read.
    static func makeConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        return configuration
    }

    // MARK: - Conversion helpers

    /// Wraps a CoreMedia PCM sample buffer in an AVAudioPCMBuffer.
    static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
