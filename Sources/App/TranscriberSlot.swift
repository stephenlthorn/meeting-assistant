import AVFoundation

/// Hands audio from a capture thread to the current transcriber. The
/// controller swaps transcribers on the main thread while audio keeps
/// arriving, so the reference lives behind a lock.
final class TranscriberSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var transcriber: LiveTranscriber?

    func set(_ transcriber: LiveTranscriber?) {
        lock.withLock { self.transcriber = transcriber }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { transcriber }?.append(buffer)
    }
}
