import Foundation

/// The overlay's placeholder wording, so each state says what is going on and
/// what to do next.
enum OverlayText {
    static func transcriptPlaceholder(for state: ListeningState) -> String {
        switch state {
        case .idle: "Not listening. Start from the menu bar icon."
        case .starting: "Starting…"
        case .listening: "Listening for audio…"
        }
    }

    static func answer(_ answer: String, isAnswering: Bool, hasKey: Bool, shortcut: String) -> String {
        if !answer.isEmpty { return answer }
        if isAnswering { return "Thinking…" }
        if !hasKey { return "Add your Anthropic API key: menu bar icon, then Settings…" }
        return "Press \(shortcut) for help"
    }
}
