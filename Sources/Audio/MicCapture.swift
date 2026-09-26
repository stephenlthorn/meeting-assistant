import Foundation
import AVFoundation

/// Captures the default microphone (your voice) via AVAudioEngine and delivers
/// mono PCM buffers. Feeds the "You" side of the transcript.
///
/// Permission: needs microphone access (NSMicrophoneUsageDescription in
/// Info.plist; the system prompt is triggered by `requestAuthorization`).
final class MicCapture: MicrophoneCapturing {
    private let engine = AVAudioEngine()
    private var tapped = false

    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onError: (@MainActor (String) -> Void)?

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
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "MicCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onBuffer?(SystemAudioCapture.downmixToMono(buffer) ?? buffer)
        }
        tapped = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        engine.stop()
    }
}
