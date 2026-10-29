import AVFoundation

/// Why capture stopped by itself. `isRetryable` is false when starting again
/// cannot help: the user chose to stop sharing, or permission was withdrawn.
struct CaptureFailure: Equatable, Sendable, ExpressibleByStringLiteral {
    let message: String
    var isRetryable = true

    init(message: String, isRetryable: Bool = true) {
        self.message = message
        self.isRetryable = isRetryable
    }

    init(stringLiteral message: String) {
        self.init(message: message)
    }
}

/// The Mac's system audio output: the other people on the call.
protocol SystemAudioCapturing: AnyObject {
    /// Called on a capture thread with each chunk of audio.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
    /// Called on the main actor when the running stream stops unexpectedly. Only
    /// the stream that is current reports: a late error from one that was
    /// already stopped or replaced is dropped.
    var onError: (@MainActor (CaptureFailure) -> Void)? { get set }
    func start() async throws
    func stop() async
}

/// The default microphone: your side of the call.
protocol MicrophoneCapturing: AnyObject {
    /// Called on a capture thread with each chunk of audio.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
    /// Called on the main actor when capture stops unexpectedly.
    var onError: (@MainActor (String) -> Void)? { get set }
    /// Called on the main actor when capture that stopped by itself and was
    /// reported through `onError` is working again.
    var onRecovered: (@MainActor () -> Void)? { get set }
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
