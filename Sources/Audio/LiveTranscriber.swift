import AVFoundation

/// Common interface for the live transcription backends, so the rest of the app
/// does not care which engine is running.
protocol LiveTranscriber: AnyObject {
    var onSegment: ((_ text: String, _ isFinal: Bool) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func requestAuthorization(_ completion: @escaping (Bool) -> Void)
    func start()
    func stop()
    func append(_ buffer: AVAudioPCMBuffer)
}

/// Picks the backend: Deepgram cloud when enabled and keyed, otherwise on-device
/// (SpeechAnalyzer on macOS 26+, SFSpeechRecognizer on 14–15).
enum TranscriberFactory {
    @MainActor
    static func make(localeIdentifier: String = "en-US") -> LiveTranscriber {
        let settings = AppSettings.shared
        if settings.useCloudSTT, let key = settings.resolveDeepgramKey(), !key.isEmpty {
            return CloudTranscriber(apiKey: key, localeIdentifier: localeIdentifier)
        }
        if #available(macOS 26, *) {
            return AnalyzerTranscriber(localeIdentifier: localeIdentifier)
        }
        return LegacySpeechTranscriber(localeIdentifier: localeIdentifier)
    }
}
