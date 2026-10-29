import Foundation

/// Builds the user message sent to Claude. The transcript includes whatever
/// the other people on the call say, so it is fenced in `<transcript>` tags
/// and the fence cannot be closed from inside it; the system prompt tells the
/// model that everything inside is data, never instructions.
enum AnswerPrompt {
    static func user(transcript: String) -> String {
        """
        Live conversation transcript so far (You = me, Them = the other participants):

        <transcript>
        \(neutralised(transcript))
        </transcript>

        Based on the latest exchange, give me help right now. Be concise.
        """
    }

    /// Replaces any `<transcript>` or `</transcript>` in spoken text (any case,
    /// stray spaces or attributes included) with a bracketed stand-in, so
    /// speech cannot end the fence early or open a second one.
    static func neutralised(_ text: String) -> String {
        text.replacingOccurrences(of: tagPattern, with: "[$1transcript]", options: [.regularExpression, .caseInsensitive])
    }

    private static let tagPattern = #"<\s*(/?)\s*transcript\b(?:[^<>\n]{0,40}>)?"#
}
