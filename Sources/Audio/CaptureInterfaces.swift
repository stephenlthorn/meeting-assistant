import AVFoundation

/// The Mac's system audio output: the other people on the call.
protocol SystemAudioCapturing: AnyObject {
    /// Called on a capture thread with each chunk of audio.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
    /// Called on the main actor when capture stops unexpectedly.
    var onError: (@MainActor (String) -> Void)? { get set }
    func start() async throws
    func stop() async
}

/// The default microphone: your side of the call.
protocol MicrophoneCapturing: AnyObject {
    /// Called on a capture thread with each chunk of audio.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
    /// Called on the main actor when capture stops unexpectedly.
    var onError: (@MainActor (String) -> Void)? { get set }
    /// Calls back on the main thread.
    func requestAuthorization(_ completion: @escaping (Bool) -> Void)
    func start() throws
    func stop()
}

enum SystemAudioError: LocalizedError, Equatable {
    case permissionDenied
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Screen Recording permission is off."
        case .noDisplay: "No display available for capture."
        }
    }
}

/// Runs `work` on a background queue after `delay` seconds.
func runAfter(_ delay: TimeInterval, _ work: @escaping () -> Void) {
    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
}

/// Runs `work` on the main actor, in the order calls were made.
func deliverOnMain(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(work) }
}
