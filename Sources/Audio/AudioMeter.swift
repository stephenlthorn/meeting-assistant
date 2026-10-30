import AVFoundation

/// Measures one side's audio where it arrives, on the capture thread, so
/// neither the level indicator nor the health checks cost a main-actor hop per
/// buffer. Each buffer updates a few counters under a lock; the loudness goes
/// out at most ten times a second, and the counters are read on demand.
final class AudioMeter: @unchecked Sendable {
    /// What the health checks need: whether audio is arriving at all, and how
    /// much of it sounded like a voice (above room noise, below quiet speech).
    struct Reading: Equatable {
        var buffers: Int
        var voicedSeconds: TimeInterval
    }

    /// About -40 dBFS.
    static let voiceLevel: Float = 0.01
    static let publishInterval: TimeInterval = 0.1

    private let clock: @Sendable () -> TimeInterval
    private let onLevel: @Sendable (Float) -> Void
    private let lock = NSLock()
    private var buffers = 0
    private var voicedSeconds: TimeInterval = 0
    private var energy = 0.0
    private var frames = 0.0
    private var lastPublished = -TimeInterval.infinity

    /// `clock` is monotonic seconds; `onLevel` is called on the capture thread
    /// with the RMS loudness since the previous call.
    init(clock: @escaping @Sendable () -> TimeInterval, onLevel: @escaping @Sendable (Float) -> Void) {
        self.clock = clock
        self.onLevel = onLevel
    }

    func observe(_ buffer: AVAudioPCMBuffer) {
        let rms = AudioMath.rms(buffer)
        let count = Double(buffer.frameLength)
        let rate = buffer.format.sampleRate
        let now = clock()
        let level = lock.withLock { () -> Float? in
            buffers += 1
            if rms >= Self.voiceLevel, rate > 0 { voicedSeconds += count / rate }
            energy += Double(rms) * Double(rms) * count
            frames += count
            guard now - lastPublished >= Self.publishInterval, frames > 0 else { return nil }
            lastPublished = now
            defer {
                energy = 0
                frames = 0
            }
            return Float((energy / frames).squareRoot())
        }
        if let level { onLevel(level) }
    }

    func reading() -> Reading {
        lock.withLock { Reading(buffers: buffers, voicedSeconds: voicedSeconds) }
    }
}
