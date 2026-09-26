import Foundation

/// Use-case prompt profiles. Pick one per call from the menu bar; the selected
/// profile's `systemPrompt` steers how the model responds to the live transcript.
enum Profile: String, CaseIterable, Identifiable {
    case general = "General"
    case sales = "Sales"
    case support = "Support"
    case standup = "Standup"

    var id: String { rawValue }

    var systemPrompt: String {
        let shared = """
        You are a real-time assistant helping the user during a live meeting. You \
        receive a running transcript of what is being said. Respond in a few short \
        bullet points that the user can glance at and act on immediately. Be concise \
        and specific. Do not restate the transcript. If nothing needs a response yet, \
        say so in one line.
        """
        switch self {
        case .general:
            return shared + " Surface the key point being discussed and a strong follow-up question or next step."
        case .sales:
            return shared + " Focus on the prospect's stated needs and objections. Suggest crisp objection-handling lines and relevant proof points."
        case .support:
            return shared + " Focus on diagnosing the reported problem and the most likely fix or next troubleshooting step."
        case .standup:
            return shared + " Track decisions, blockers, and action items as they come up, and flag anything that needs the user's input."
        }
    }
}
