import Foundation

/// Heuristic for "the other side just asked something", used by auto-answer.
/// Punctuated text is judged by its last sentence's closing mark; unpunctuated
/// text (some recognizers emit none) falls back to how that sentence opens.
enum QuestionDetector {
    private static let openers = [
        "what", "what's", "whats", "why", "how", "how's", "when", "where", "where's",
        "who", "who's", "whose", "which",
        "is", "isn't", "are", "aren't", "was", "were", "do", "does", "did", "don't", "doesn't",
        "can", "can't", "could", "would", "will", "won't", "should", "have", "has",
        "tell me", "walk me through", "explain", "any thoughts",
    ]

    private static let fillers: Set<String> = [
        "so", "and", "but", "okay", "ok", "um", "uh", "well", "right", "alright", "also", "yeah", "now",
    ]

    static func looksLikeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 3, let closing = trimmed.last else { return false }
        switch closing {
        case "?": return true
        case ".", "!": return false
        default: return opensLikeAQuestion(lastSentence(of: trimmed))
        }
    }

    private static func lastSentence(of text: String) -> String {
        let start = text.lastIndex(where: { ".?!".contains($0) }).map { text.index(after: $0) } ?? text.startIndex
        return String(text[start...])
    }

    private static func opensLikeAQuestion(_ sentence: String) -> Bool {
        let words = sentence.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
            .drop(while: { fillers.contains($0) })
        let opening = words.joined(separator: " ")
        return openers.contains { opening == $0 || opening.hasPrefix($0 + " ") }
    }
}
