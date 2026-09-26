import AVFoundation

/// Common interface for the live transcription backends, so the rest of the
/// app does not care which engine is running.
///
/// Callbacks arrive on the main actor; `append` may be called from any thread.
/// Each backend starts a new utterance id after every final segment.
protocol LiveTranscriber: AnyObject {
    /// Shown in the status line, e.g. "on-device" or "Deepgram".
    var backendName: String { get }
    var onSegment: (@MainActor (TranscriptSegment) -> Void)? { get set }
    var onError: (@MainActor (String) -> Void)? { get set }
    /// A passing status such as a model download; nil clears it.
    var onNotice: (@MainActor (String?) -> Void)? { get set }
    /// Calls back on the main thread.
    func requestAuthorization(_ completion: @escaping (Bool) -> Void)
    func start()
    func stop()
    func append(_ buffer: AVAudioPCMBuffer)
}

/// Picks the backend: Deepgram cloud when enabled and keyed, otherwise on-device
/// (SpeechAnalyzer on macOS 26+, SFSpeechRecognizer on 14–15).
enum TranscriberFactory {
    @MainActor
    static func make(settings: AppSettings, localeIdentifier: String = "en-US") -> LiveTranscriber {
        if settings.useCloudSTT, let key = settings.resolveDeepgramKey() {
            return CloudTranscriber(apiKey: key, localeIdentifier: localeIdentifier)
        }
        if #available(macOS 26, *) {
            return AnalyzerTranscriber(localeIdentifier: localeIdentifier)
        }
        return LegacySpeechTranscriber(localeIdentifier: localeIdentifier)
    }
}
