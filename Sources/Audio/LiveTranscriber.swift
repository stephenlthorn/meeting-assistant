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
    /// The transcriber has stopped for good and will not recover on its own: it
    /// refused to start (a missing or rejected key, no on-device model) or ran
    /// out of retries. The reason is also reported through `onError`, so a
    /// consumer that only lists problems needs nothing more; this is how the
    /// owner learns the side is dead rather than merely struggling.
    var onFatal: (@MainActor (String) -> Void)? { get set }
    /// A passing status such as a model download; nil clears it.
    var onNotice: (@MainActor (String?) -> Void)? { get set }
    /// Calls back on the main thread.
    func requestAuthorization(_ completion: @escaping (Bool) -> Void)
    func start()
    func stop()
    func append(_ buffer: AVAudioPCMBuffer)
}

/// Which backend a listening session uses, decided from the settings alone
/// (no Keychain read). The controller keeps the plan a session started with
/// and compares it to the current one when a setting changes mid-call.
enum SpeechPlan: Equatable {
    /// Audio streams to Deepgram: switched on, agreed to, and keyed.
    case deepgram
    /// SpeechAnalyzer, macOS 26+: always on this Mac.
    case analyzer
    /// SFSpeechRecognizer, macOS 14-15. It sends audio to Apple's servers only
    /// when this Mac cannot transcribe the language on-device and the user
    /// allowed that.
    case legacy(allowServerRecognition: Bool)
}

/// Picks the backend: Deepgram cloud when enabled, agreed to and keyed,
/// otherwise on-device (SpeechAnalyzer on macOS 26+, SFSpeechRecognizer on 14-15).
enum TranscriberFactory {
    /// Whether SpeechAnalyzer can run. Tests set it to reach the macOS 14-15
    /// path on a newer system.
    @MainActor static var analyzerAvailable: Bool = {
        if #available(macOS 26, *) { return true }
        return false
    }()

    @MainActor
    static func plan(for settings: AppSettings) -> SpeechPlan {
        plan(for: settings, analyzerAvailable: analyzerAvailable)
    }

    @MainActor
    static func plan(for settings: AppSettings, analyzerAvailable: Bool) -> SpeechPlan {
        if settings.sendsAudioToDeepgram { return .deepgram }
        return analyzerAvailable ? .analyzer : .legacy(allowServerRecognition: settings.serverSpeechAccepted)
    }

    @MainActor
    static func make(settings: AppSettings, localeIdentifier: String = "en-US") -> LiveTranscriber {
        if settings.sendsAudioToDeepgram, let key = settings.resolveDeepgramKey() {
            return CloudTranscriber(apiKey: key, localeIdentifier: localeIdentifier)
        }
        // Past this point Deepgram is out, including when its key could not be read.
        if analyzerAvailable, #available(macOS 26, *) {
            return AnalyzerTranscriber(localeIdentifier: localeIdentifier)
        }
        return LegacySpeechTranscriber(localeIdentifier: localeIdentifier,
                                       allowServerRecognition: settings.serverSpeechAccepted)
    }
}
