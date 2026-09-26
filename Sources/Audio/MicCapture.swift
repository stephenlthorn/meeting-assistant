import AVFoundation

/// The parts of AVAudioEngine's input that microphone capture uses, so tests
/// can simulate devices.
protocol AudioInputEngine: AnyObject {
    /// The input device's current format, or nil when there is no usable input.
    var inputFormat: AVAudioFormat? { get }
    /// Called on any thread when the input device or its format changes; the
    /// engine has stopped itself by then.
    var onConfigurationChange: (() -> Void)? { get set }
    func installTap(format: AVAudioFormat, block: @escaping (AVAudioPCMBuffer) -> Void)
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
/// Permission: needs microphone access (NSMicrophoneUsageDescription in
/// Info.plist; the system prompt is triggered by `requestAuthorization`).
final class MicCapture: MicrophoneCapturing {
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onError: (@MainActor (String) -> Void)?

    private let engine: AudioInputEngine
    private var running = false

    init(engine: AudioInputEngine = AVAudioInputEngine()) {
        self.engine = engine
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
        engine.removeTap()
        engine.stop()
    }

    private func startTap() throws {
        guard let format = engine.inputFormat else { throw MicrophoneError.noInputDevice }
        engine.installTap(format: format) { [weak self] buffer in
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
        engine.removeTap()
        engine.stop()
        do {
            try startTap()
        } catch {
            running = false
            onError?("Couldn't restart after the input device changed: \(error.localizedDescription)")
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

    func installTap(format: AVAudioFormat, block: @escaping (AVAudioPCMBuffer) -> Void) {
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
