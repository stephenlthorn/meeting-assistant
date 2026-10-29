import Foundation

/// Judges, from periodic readings of one side's audio, whether that side has
/// silently broken: capture that stopped delivering buffers, or a transcriber
/// that hears a voice and writes nothing. It only decides; the owner acts, and
/// tells it when something was started again.
///
/// Both problems get one automatic restart. If the side is still broken after
/// that, the user is told once and the restarts stop, because a call that is
/// merely quiet must not be restarted every half minute for ever. Good news
/// (audio flowing, text arriving) resets the budget.
struct SideWatchdog {
    struct Limits: Equatable {
        /// No buffers at all for this long means capture is dead.
        var captureStall: TimeInterval = 30
        /// A window this long with voice and no text means the transcriber is dead.
        var textStall: TimeInterval = 60
        /// Voice needed in that window: a cough or a keyboard is not a conversation.
        var minimumVoice: TimeInterval = 10
    }

    enum Verdict: Equatable {
        case restartCapture
        /// Capture was restarted and is still silent. Said once.
        case captureStillSilent
        /// Audio is flowing again after `captureStillSilent`.
        case captureResumed
        case restartTranscriber
        /// The transcriber was restarted and still writes nothing. Said once.
        case transcriberStillSilent
    }

    private let limits: Limits
    private var lastBuffers: Int
    private var lastAudioAt: Date
    private var captureRestarted = false
    private var reportedSilence = false
    private var windowStart: Date
    private var voicedAtWindowStart: TimeInterval
    private var textInWindow = false
    private var transcriberRestarted = false
    private var reportedNoText = false
    /// Whether any buffer arrived since the previous check.
    private(set) var isHearingAudio = true

    init(at now: Date, reading: AudioMeter.Reading, limits: Limits = Limits()) {
        self.limits = limits
        lastBuffers = reading.buffers
        lastAudioAt = now
        windowStart = now
        voicedAtWindowStart = reading.voicedSeconds
    }

    /// The side was (re)started, or time jumped (the Mac slept): forget how long
    /// it has been quiet. What was already restarted or reported is remembered.
    mutating func rearm(at now: Date, reading: AudioMeter.Reading) {
        lastBuffers = reading.buffers
        lastAudioAt = now
        windowStart = now
        voicedAtWindowStart = reading.voicedSeconds
        textInWindow = false
    }

    /// A transcript segment arrived. Returns whether a "nothing is being
    /// transcribed" report was standing, so the owner can take it down.
    mutating func noteText() -> Bool {
        textInWindow = true
        transcriberRestarted = false
        defer { reportedNoText = false }
        return reportedNoText
    }

    mutating func check(_ reading: AudioMeter.Reading, at now: Date) -> Verdict? {
        checkCapture(reading, at: now) ?? checkText(reading, at: now)
    }

    private mutating func checkCapture(_ reading: AudioMeter.Reading, at now: Date) -> Verdict? {
        if reading.buffers != lastBuffers {
            lastBuffers = reading.buffers
            lastAudioAt = now
            isHearingAudio = true
            captureRestarted = false
            guard reportedSilence else { return nil }
            reportedSilence = false
            return .captureResumed
        }
        isHearingAudio = false
        guard now.timeIntervalSince(lastAudioAt) >= limits.captureStall else { return nil }
        lastAudioAt = now
        guard captureRestarted else {
            captureRestarted = true
            return .restartCapture
        }
        guard !reportedSilence else { return nil }
        reportedSilence = true
        return .captureStillSilent
    }

    /// Judged in whole windows, so speech that merely started a moment ago is
    /// never held against a transcriber that is still working on it.
    private mutating func checkText(_ reading: AudioMeter.Reading, at now: Date) -> Verdict? {
        guard now.timeIntervalSince(windowStart) >= limits.textStall else { return nil }
        let heardVoice = reading.voicedSeconds - voicedAtWindowStart >= limits.minimumVoice
        let silent = heardVoice && !textInWindow
        windowStart = now
        voicedAtWindowStart = reading.voicedSeconds
        textInWindow = false
        guard silent else { return nil }
        guard transcriberRestarted else {
            transcriberRestarted = true
            return .restartTranscriber
        }
        guard !reportedNoText else { return nil }
        reportedNoText = true
        return .transcriberStillSilent
    }
}
