import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures the Mac's system audio output (what your speakers/headphones play,
/// i.e. the other people on the call) using ScreenCaptureKit. No virtual audio
/// device required on macOS 13+. Delivers mono PCM buffers to `onBuffer`.
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

        // We capture the whole display's audio. Video is required by SCStream but
        // we keep it tiny and never read the frames.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true   // don't record our own sounds
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 6) // ~6fps, ignored

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
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
        onBuffer?(Self.downmixToMono(pcm) ?? pcm)
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

    /// Averages channels into a single mono buffer (better for speech recognition).
    /// Returns nil if the layout is interleaved (caller falls back to the original).
    static func downmixToMono(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let channelData = input.floatChannelData else { return nil }
        let channels = Int(input.format.channelCount)
        if channels == 1 { return input }

        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: input.format.sampleRate,
                                             channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: input.frameCapacity) else {
            return nil
        }
        mono.frameLength = input.frameLength
        let out = mono.floatChannelData![0]
        let count = Int(input.frameLength)
        for i in 0..<count {
            var sum: Float = 0
            for c in 0..<channels { sum += channelData[c][i] }
            out[i] = sum / Float(channels)
        }
        return mono
    }
}
