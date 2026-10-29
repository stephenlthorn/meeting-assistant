import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures the Mac's system audio output (what your speakers/headphones play,
/// i.e. the other people on the call) using ScreenCaptureKit. No virtual audio
/// device required on macOS 13+. Delivers mono PCM buffers to `onBuffer`,
/// requested at 16 kHz since that is all speech recognition needs.
///
/// Permission: first `start()` triggers the system "Screen Recording" prompt
/// (ScreenCaptureKit is gated by that TCC permission even for audio-only use).
///
/// Audio and errors are only accepted from the current stream: stopping or
/// replacing it makes the old one irrelevant, so a late error from a stream
/// that was already stopped cannot be mistaken for a failure of its successor.
final class SystemAudioCapture: NSObject, SystemAudioCapturing, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var stream: SCStream? // guarded by `lock`
    private let audioQueue = DispatchQueue(label: "meetingassistant.audio.capture")

    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onError: (@MainActor (CaptureFailure) -> Void)?

    func start() async throws {
        do {
            try await startStream()
        } catch let error as SystemAudioError {
            throw error
        } catch {
            guard CGPreflightScreenCaptureAccess() else {
                CGRequestScreenCaptureAccess()
                throw SystemAudioError.permissionDenied
            }
            throw error
        }
    }

    private func startStream() async throws {
        await stop()
        let content = try await SCShareableContent.current
        guard let display = Self.preferredDisplay(content.displays, mainDisplayID: CGMainDisplayID(),
                                                  id: \.displayID) else { throw SystemAudioError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: Self.makeConfiguration(), delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        lock.withLock { self.stream = stream }
        do {
            try await stream.startCapture()
        } catch {
            lock.withLock { if self.stream === stream { self.stream = nil } }
            throw error
        }
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

    func stop() async {
        let stream = lock.withLock { () -> SCStream? in
            defer { self.stream = nil }
            return self.stream
        }
        try? await stream?.stopCapture()
    }

    private func isCurrent(_ stream: SCStream) -> Bool {
        lock.withLock { self.stream === stream }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio,
              isCurrent(stream),
              sampleBuffer.isValid,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let pcm = Self.makePCMBuffer(from: sampleBuffer) else { return }
        onBuffer?(AudioMath.monoMix(pcm) ?? pcm)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let wasCurrent = lock.withLock { () -> Bool in
            guard self.stream === stream else { return false }
            self.stream = nil
            return true
        }
        guard wasCurrent else { return }
        let onError = self.onError
        let failure = CaptureFailure(message: error.localizedDescription, isRetryable: Self.isRetryable(error))
        deliverOnMain { onError?(failure) }
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
