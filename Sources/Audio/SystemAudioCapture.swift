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
final class SystemAudioCapture: NSObject, SystemAudioCapturing, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "meetingassistant.audio.capture")

    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onError: (@MainActor (String) -> Void)?

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
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw SystemAudioError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: Self.makeConfiguration(), delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
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
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let pcm = Self.makePCMBuffer(from: sampleBuffer) else { return }
        onBuffer?(AudioMath.monoMix(pcm) ?? pcm)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let onError = self.onError
        let message = error.localizedDescription
        deliverOnMain { onError?(message) }
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
