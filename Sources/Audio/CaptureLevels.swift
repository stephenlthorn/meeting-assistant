import Observation

/// How loud each side of the call is right now, for the overlay's level
/// indicator. Values sit on the meter scale (0...1). They rise at once and ease
/// down, since they arrive about ten times a second. A side that is not
/// capturing reads zero, and a late report for it is ignored.
@MainActor
@Observable
final class CaptureLevels {
    /// How much of the level is kept at each update when nothing louder arrives.
    static let release: Float = 0.75

    private(set) var you: Float = 0
    private(set) var them: Float = 0
    @ObservationIgnored private var capturing: Set<Speaker> = []

    func setActive(_ speaker: Speaker, _ isCapturing: Bool) {
        if isCapturing {
            capturing.insert(speaker)
        } else {
            capturing.remove(speaker)
            set(0, for: speaker)
        }
    }

    func update(_ speaker: Speaker, rms: Float) {
        guard capturing.contains(speaker) else { return }
        let held = (speaker == .you ? you : them) * Self.release
        set(max(AudioMath.meterPosition(forRMS: rms), held), for: speaker)
    }

    /// Audio stopped arriving without the side being declared down.
    func silence(_ speaker: Speaker) {
        set(0, for: speaker)
    }

    private func set(_ level: Float, for speaker: Speaker) {
        switch speaker {
        case .you where you != level: you = level
        case .them where them != level: them = level
        default: break
        }
    }
}
