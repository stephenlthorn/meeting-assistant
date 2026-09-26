import Foundation
import Speech
import AVFoundation

/// On-device speech-to-text over a live stream of audio buffers using Apple's
/// Speech framework (SFSpeechRecognizer). Because a single recognition request
/// has a practical duration limit, it rotates to a fresh request periodically.
/// This is the macOS 14–15 fallback; macOS 26+ uses AnalyzerTranscriber.
///
/// Permission: `requestAuthorization` triggers the Speech Recognition prompt.
/// Add `NSSpeechRecognitionUsageDescription` to Info.plist (project.yml does this).
final class LegacySpeechTranscriber: LiveTranscriber {
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var segmentStart = Date()
    private let rotateAfter: TimeInterval = 45
    private var running = false
    private let queue = DispatchQueue(label: "meetingassistant.speech")

    /// Emits the current segment's text and whether it is finalized. Off the main thread.
    var onSegment: ((_ text: String, _ isFinal: Bool) -> Void)?
    var onError: ((String) -> Void)?

    init(localeIdentifier: String = "en-US") {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let recognizer = self.recognizer, recognizer.isAvailable else {
                self.onError?("Speech recognizer unavailable for this locale.")
                return
            }
            self.running = true
            self.startSegment()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.request?.endAudio()
            self.task?.cancel()
            self.request = nil
            self.task = nil
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            if Date().timeIntervalSince(self.segmentStart) > self.rotateAfter {
                self.rotate()
            }
            self.request?.append(buffer)
        }
    }

    // MARK: - Private (all run on `queue`)

    private func startSegment() {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        segmentStart = Date()
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                if let result {
                    self.onSegment?(result.bestTranscription.formattedString, result.isFinal)
                }
                if error != nil, self.running {
                    self.rotate()
                }
            }
        }
    }

    private func rotate() {
        request?.endAudio()
        task = nil
        request = nil
        if running { startSegment() }
    }
}
