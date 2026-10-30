import Foundation

/// What the menu bar menu shows right now: titles, which items are enabled and
/// the notes under them. Worked out in one place from the controller and the
/// settings, so a test reads it instead of a menu.
struct MenuState: Equatable {
    let statusLine: String
    let listeningTitle: String
    let answerNowTitle: String
    let overlayTitle: String
    let canTrySample: Bool
    let canCopyAnswer: Bool
    let canCopyTranscript: Bool
    let canSaveTranscript: Bool
    let canSummarize: Bool
    let canCopySummary: Bool
    let canClearTranscript: Bool
    /// The System Settings panes that would fix what the overlay lists as problems.
    let privacyFixes: [PrivacyPane]
    /// Lines under the actions: a shortcut that could not be registered, a missing API key.
    let notes: [String]

    @MainActor
    init(controller: AssistantController, settings: AppSettings, hotKeyProblem: String?) {
        let hasTranscript = !controller.transcriptDisplay.isEmpty
        statusLine = StatusLine.text(status: controller.status, listening: controller.listening, model: settings.model)
        listeningTitle = switch controller.listening {
        case .idle: "Start Listening"
        case .starting, .listening: "Stop Listening"
        case .sample: "Stop Sample Meeting"
        }
        answerNowTitle = "Answer Now (\(settings.answerHotKey.label))"
        overlayTitle = "\(settings.showsOverlay ? "Hide" : "Show") Overlay (\(settings.overlayHotKey.label))"
        canTrySample = !controller.isListening
        canCopyAnswer = !controller.answer.isEmpty
        canCopyTranscript = hasTranscript
        canSaveTranscript = hasTranscript
        canSummarize = hasTranscript && !controller.isSummarizing
        canCopySummary = !controller.summary.isEmpty
        canClearTranscript = hasTranscript || !controller.answer.isEmpty
        privacyFixes = controller.problems.compactMap(\.fix).reduce(into: []) { fixes, pane in
            if !fixes.contains(pane) { fixes.append(pane) }
        }
        notes = [hotKeyProblem, Self.apiKeyNote(settings)].compactMap { $0 }
    }

    @MainActor
    private static func apiKeyNote(_ settings: AppSettings) -> String? {
        if settings.apiKeySource == .unreadable { return "Allow Keychain access to your API key in Settings" }
        return settings.apiKeyPresent ? nil : "Add your API key in Settings"
    }
}
