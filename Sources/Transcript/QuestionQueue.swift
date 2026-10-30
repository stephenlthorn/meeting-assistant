import Foundation

/// A question the other side asked that auto-answer could not take up at once.
struct PendingQuestion: Equatable {
    let text: String
    let detectedAt: Date
    /// How many of your own turns had finished when it was asked.
    let afterYouTurns: Int
}

/// Holds the most recent question that arrived while an answer was still
/// streaming (or inside the pause between auto-answers), so it is answered when
/// there is room, as long as it is still recent and you have not answered it
/// aloud since. An older one is replaced, with a note: the answer reads the
/// latest transcript anyway, which includes it.
struct QuestionQueue {
    /// A question older than this when its turn comes is dropped, not answered late.
    static let maxAge: TimeInterval = 30
    private static let noteQuoteLength = 50

    private(set) var waiting: PendingQuestion?

    /// Holds `text`, returning the question it replaces, if there was one.
    @discardableResult
    mutating func hold(_ text: String, at time: Date, afterYouTurns: Int) -> PendingQuestion? {
        defer { waiting = PendingQuestion(text: text, detectedAt: time, afterYouTurns: afterYouTurns) }
        return waiting
    }

    mutating func clear() {
        waiting = nil
    }

    /// The overlay's quiet line for a question that waited too long.
    static func skippedNote(for question: PendingQuestion, at time: Date) -> String {
        let seconds = Int(time.timeIntervalSince(question.detectedAt).rounded())
        return "Skipped a question from \(seconds)s ago: \"\(quoted(question))\""
    }

    /// For a question that a newer one took the place of.
    static func replacedNote(for question: PendingQuestion) -> String {
        "Skipped an earlier question: \"\(quoted(question))\""
    }

    /// For a question you answered aloud while it waited.
    static func answeredByYouNote(for question: PendingQuestion) -> String {
        "Skipped a question you already answered: \"\(quoted(question))\""
    }

    private static func quoted(_ question: PendingQuestion) -> String {
        let text = question.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > noteQuoteLength
            ? text.prefix(noteQuoteLength).trimmingCharacters(in: .whitespaces) + "…"
            : text
    }
}
