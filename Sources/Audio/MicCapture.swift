import AVFoundation

/// The parts of AVAudioEngine's input that microphone capture uses, so tests
/// can simulate devices.
protocol AudioInputEngine: AnyObject {
    /// The input device's current format, or nil when there is no usable input.
    var inputFormat: AVAudioFormat? { get }
    /// Called on any thread when the input device or its format changes; the
    /// engine has stopped itself by then.
    var onConfigurationChange: (() -> Void)? { get set }
    /// A nil format taps the input in whatever format it has at that moment;
    /// naming one that has since changed raises an exception that cannot be caught.
    func installTap(format: AVAudioFormat?, block: @escaping (AVAudioPCMBuffer) -> Void)
    func removeTap()
    func start() throws
    func stop()
}

enum MicrophoneError: LocalizedError {
    case noInputDevice

    var errorDescription: String? { "No microphone input available." }
}

/// Captures the default microphone (your voice) and delivers mono PCM
/// buffers for the "You" side of the transcript.
///
/// Start is idempotent (a second tap on the input bus would crash
/// AVAudioEngine), and a change of input device, such as connecting AirPods
/// mid-call, restarts capture with the new device's format.
///
/// A restart that fails (a Bluetooth headset can briefly have no input at all)
/// does not end capture: the microphone stays armed, retries with backoff, and
/// tries again on the next device change. The failure is reported through
/// `onError` only once the retries run out, so a blip is not worth interrupting
/// a call for, and `onRecovered` says when it works again.
///
/// Permission: needs microphone access (NSMicrophoneUsageDescription in
/// Info.plist; the system prompt is triggered by `requestAuthorization`).
final class MicCapture: MicrophoneCapturing {
    /// Waits before each retry of a failed restart, about half a minute in all.
    static let retryDelays: [TimeInterval] = [1, 2, 4, 8, 15]

    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onRecovered: (@MainActor () -> Void)?

    private let engine: AudioInputEngine
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    // Touched on the main thread only. `running` means armed: the caller wants
    // the microphone, whether or not a tap is installed right now.
    private var running = false
    private var failedRestarts = 0
    private var pendingRetry = 0
    private var reportedFailure = false

    init(engine: AudioInputEngine = AVAudioInputEngine(),
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = runAfter) {
        self.engine = engine
        self.schedule = schedule
        engine.onConfigurationChange = { [weak self] in
            deliverOnMain { self?.restartAfterConfigurationChange() }
        }
    }

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func start() throws {
        guard !running else { return }
        try startTap()
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        pendingRetry += 1
        failedRestarts = 0
        reportedFailure = false
        engine.removeTap()
        engine.stop()
    }

    /// Checks there is an input, then taps it in whatever format it has now. The
    /// format is not read first and passed in: if the device changes in between,
    /// AVAudioEngine raises an Objective-C exception that Swift cannot catch.
    private func startTap() throws {
        guard engine.inputFormat != nil else { throw MicrophoneError.noInputDevice }
        engine.installTap(format: nil) { [weak self] buffer in
            guard let onBuffer = self?.onBuffer else { return }
            onBuffer(AudioMath.monoMix(buffer) ?? buffer)
        }
        do {
            try engine.start()
        } catch {
            engine.removeTap()
            throw error
        }
    }

    @MainActor
    private func restartAfterConfigurationChange() {
        guard running else { return }
        failedRestarts = 0
        restart()
    }

    @MainActor
    private func restart() {
        pendingRetry += 1
        engine.removeTap()
        engine.stop()
        do {
            try startTap()
            failedRestarts = 0
            if reportedFailure {
                reportedFailure = false
                onRecovered?()
            }
        } catch {
            failedRestarts += 1
            guard failedRestarts <= Self.retryDelays.count else {
                guard !reportedFailure else { return }
                reportedFailure = true
                onError?("Couldn't restart after the input device changed: \(error.localizedDescription)")
                return
            }
            retry(after: Self.retryDelays[failedRestarts - 1])
        }
    }

    @MainActor
    private func retry(after delay: TimeInterval) {
        let attempt = pendingRetry
        schedule(delay) { [weak self] in
            deliverOnMain {
                guard let self, self.running, self.pendingRetry == attempt else { return }
                self.restart()
            }
        }
    }
}

/// AVAudioEngine's input node behind AudioInputEngine.
final class AVAudioInputEngine: AudioInputEngine {
    var onConfigurationChange: (() -> Void)?
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var inputFormat: AVAudioFormat? {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0 ? format : nil
    }

    func installTap(format: AVAudioFormat?, block: @escaping (AVAudioPCMBuffer) -> Void) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in block(buffer) }
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}
