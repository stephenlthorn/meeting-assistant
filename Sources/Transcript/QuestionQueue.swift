import Foundation

/// A question the other side asked that auto-answer could not take up at once.
struct PendingQuestion: Equatable {
    let text: String
    let detectedAt: Date
}

/// Holds the most recent question that arrived while an answer was still
/// streaming (or inside the pause between auto-answers), so it is answered when
/// there is room, as long as it is still recent. An older one is replaced: the
/// answer reads the latest transcript anyway, which includes it.
struct QuestionQueue {
    /// A question older than this when its turn comes is dropped, not answered late.
    static let maxAge: TimeInterval = 30
    private static let noteQuoteLength = 50

    private(set) var waiting: PendingQuestion?

    mutating func hold(_ text: String, at time: Date) {
        waiting = PendingQuestion(text: text, detectedAt: time)
    }

    mutating func clear() {
        waiting = nil
    }

    /// The overlay's quiet line for a question that waited too long.
    static func skippedNote(for question: PendingQuestion, at time: Date) -> String {
        let seconds = Int(time.timeIntervalSince(question.detectedAt).rounded())
        let text = question.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = text.count > noteQuoteLength
            ? text.prefix(noteQuoteLength).trimmingCharacters(in: .whitespaces) + "…"
            : text
        return "Skipped a question from \(seconds)s ago: \"\(quoted)\""
    }
}
