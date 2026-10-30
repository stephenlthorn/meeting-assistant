import Foundation

/// A scripted sales call for trying the app without a live meeting. Nothing
/// is recorded. Until the privacy terms are accepted, or without an API key,
/// canned answers and a canned summary stand in for Claude and nothing is sent
/// anywhere. After that, with a key, the sample transcript (not a real
/// conversation) goes to Claude, without the user's own extra instructions.
enum SampleMeeting {
    struct Line: Equatable {
        let speaker: Speaker
        let text: String
    }

    static let lineInterval: TimeInterval = 2.5

    static let lines = [
        Line(speaker: .them, text: "Thanks for making the time. We run twelve dental offices and our front desks miss a lot of calls."),
        Line(speaker: .you, text: "Got it. What happens to those missed calls today?"),
        Line(speaker: .them, text: "Most go to voicemail, and maybe half get a callback the same day."),
        Line(speaker: .them, text: "What would it take to get every caller a response within a few minutes?"),
        Line(speaker: .you, text: "Good question. Let me walk you through how we'd approach it."),
        Line(speaker: .them, text: "And how long would a rollout across all twelve offices take?"),
    ]

    static let sampleAnswerIntro = "Sample answer (add your Anthropic API key in Settings for live answers from Claude):\n"

    /// Stand-ins for Claude's answers when no API key is set, one per question.
    static let sampleAnswers = [
        "- Text back every missed call within a minute with a booking link\n- Send after-hours calls to an AI receptionist that books appointments\n- Ask which scheduling software the offices use",
        "- Pilot one office for two weeks, then roll out four offices at a time\n- About six weeks for all twelve\n- Ask who owns front-desk operations across the offices",
    ]

    /// Stands in for Claude's summary while the sample plays before the privacy terms are accepted.
    static let sampleSummary = """
        Sample summary (accept the privacy terms and add your Anthropic API key in Settings for real summaries from Claude):

        ## Summary
        The prospect runs twelve dental offices whose front desks miss a lot of calls, and wants every caller answered within minutes.

        ## Decisions
        - None yet

        ## Action items
        - Owner not stated: walk through how missed calls would get a fast response
        - Owner not stated: scope a rollout across all twelve offices
        """

    /// Streams `text` word by word, like a live answer.
    static func streamAnswer(_ text: String, wordDelay: TimeInterval) -> AsyncThrowingStream<String, Error> {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for (index, word) in words.enumerated() {
                    if wordDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(wordDelay * 1_000_000_000)) }
                    guard !Task.isCancelled else { break }
                    continuation.yield(index == 0 ? word : " " + word)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
