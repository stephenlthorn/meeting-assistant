import Foundation
import AVFoundation
import AppKit

/// Which side of the conversation a transcript line came from.
enum Speaker: String {
    case you = "You"
    case them = "Them"
}

/// Orchestrates the pipeline: system audio (them) + microphone (you) feed two
/// transcribers, whose segments merge into one speaker-labeled transcript. On a
/// manual trigger (or auto-answer) the recent transcript is sent to the LLM.
/// Transcribers are created per session so a Settings change (e.g. cloud STT)
/// applies on the next Start.
@MainActor
final class AssistantController: ObservableObject {
    @Published var transcript = ""
    @Published var answer = ""
    @Published var status = "Idle"
    @Published var isListening = false

    private let settings = AppSettings.shared
    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()
    private var themTranscriber: LiveTranscriber?
    private var youTranscriber: LiveTranscriber?
    private let llm = LLMClient()
    private var answerTask: Task<Void, Never>?
    private var lastAutoAnswer = Date.distantPast

    private struct Turn { let speaker: Speaker; var text: String; var isFinal: Bool }
    private var turns: [Turn] = []
    private var activeIndex: [Speaker: Int] = [:]

    init() {
        systemCapture.onBuffer = { [weak self] buffer in self?.themTranscriber?.append(buffer) }
        systemCapture.onError = { [weak self] message in
            Task { @MainActor in self?.status = "System audio: \(message)" }
        }
        micCapture.onBuffer = { [weak self] buffer in self?.youTranscriber?.append(buffer) }
        micCapture.onError = { [weak self] message in
            Task { @MainActor in self?.status = "Mic: \(message)" }
        }
    }

    func toggleListening() { isListening ? stop() : start() }

    func start() {
        clearTranscript()
        let them = TranscriberFactory.make()
        wire(them, .them)
        themTranscriber = them
        let you = TranscriberFactory.make()
        wire(you, .you)
        youTranscriber = you

        // Speech authorization is process-wide and shared (cloud/analyzer return true).
        them.requestAuthorization { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.status = "Speech permission denied"
                return
            }
            self.startThemSide()
            self.startYouSide()
        }
    }

    private func wire(_ transcriber: LiveTranscriber, _ speaker: Speaker) {
        transcriber.onSegment = { [weak self] text, isFinal in
            Task { @MainActor in self?.ingest(speaker, text, isFinal) }
        }
        transcriber.onError = { [weak self] message in
            Task { @MainActor in self?.status = "\(speaker.rawValue): \(message)" }
        }
    }

    private func startThemSide() {
        themTranscriber?.start()
        Task {
            do {
                try await systemCapture.start()
                isListening = true
                status = statusLabel()
            } catch {
                status = "System audio failed: \(error.localizedDescription)"
            }
        }
    }

    private func startYouSide() {
        micCapture.requestAuthorization { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.status = "Listening (mic denied: their side only)"
                return
            }
            self.youTranscriber?.start()
            do {
                try self.micCapture.start()
            } catch {
                self.status = "Mic failed: \(error.localizedDescription)"
            }
        }
    }

    private func statusLabel() -> String {
        (settings.useCloudSTT && settings.deepgramKeyPresent) ? "Listening (Deepgram)" : "Listening"
    }

    func stop() {
        let systemCapture = self.systemCapture
        Task { await systemCapture.stop() }
        micCapture.stop()
        themTranscriber?.stop()
        themTranscriber = nil
        youTranscriber?.stop()
        youTranscriber = nil
        isListening = false
        status = "Stopped"
    }

    func answerNow() {
        answerTask?.cancel()
        let context = String(transcript.suffix(4000))
        guard !context.isEmpty else {
            answer = "(No transcript yet. Start listening first.)"
            return
        }
        guard let apiKey = settings.resolveAPIKey() else {
            answer = "No API key. Add one in Settings (⌘,)."
            status = "Needs API key"
            return
        }
        answer = ""
        status = "Thinking..."
        let model = settings.model
        let system = systemPrompt()
        let user = """
        Live conversation transcript so far (You = me, Them = the other participants):

        \(context)

        Based on the latest exchange, give me help right now. Be concise.
        """
        answerTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.llm.stream(apiKey: apiKey, model: model, system: system, user: user) { delta in
                    Task { @MainActor in self.answer += delta }
                }
                self.status = self.isListening ? self.statusLabel() : "Idle"
            } catch {
                self.answer = "Error: \(error.localizedDescription)"
                self.status = "Error"
            }
        }
    }

    func clearTranscript() {
        turns.removeAll()
        activeIndex.removeAll()
        transcript = ""
        answer = ""
    }

    func copyTranscript() {
        guard !transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    // MARK: - Prompt

    private func systemPrompt() -> String {
        let base = settings.profile.systemPrompt
        let extra = settings.extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? base : base + "\n\nAdditional instructions from the user:\n" + extra
    }

    // MARK: - Transcript merge

    /// Merges per-side segments into one ordered, speaker-labeled transcript.
    /// Each side keeps one in-progress turn that updates in place until it
    /// finalizes; new turns append in the order their segments start.
    private func ingest(_ speaker: Speaker, _ text: String, _ isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = activeIndex[speaker], index < turns.count {
            turns[index].text = trimmed
            turns[index].isFinal = isFinal
            if isFinal { activeIndex[speaker] = nil }
        } else if !trimmed.isEmpty {
            turns.append(Turn(speaker: speaker, text: trimmed, isFinal: isFinal))
            if !isFinal { activeIndex[speaker] = turns.count - 1 }
        }
        transcript = turns
            .filter { !$0.text.isEmpty }
            .map { "\($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")

        if speaker == .them, isFinal, settings.autoAnswer, looksLikeQuestion(trimmed) {
            if Date().timeIntervalSince(lastAutoAnswer) > 6 {
                lastAutoAnswer = Date()
                answerNow()
            }
        }
    }

    private func looksLikeQuestion(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lowered.count > 3 else { return false }
        if lowered.hasSuffix("?") { return true }
        let starters = ["what", "why", "how", "when", "where", "who", "which",
                        "can you", "could you", "would you", "do you", "did you",
                        "are you", "is there", "tell me", "walk me through", "explain"]
        return starters.contains { lowered.hasPrefix($0 + " ") || lowered == $0 }
    }
}
