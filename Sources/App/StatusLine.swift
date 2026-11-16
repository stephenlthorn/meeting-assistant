import Foundation

/// The one-line status in the overlay and the menu. The controller's status
/// already names the speech backend ("Listening (on-device)", "(Deepgram)",
/// "(Apple servers)"); while a call is being listened to, this adds the Claude
/// model answers come from, so where audio and transcript text can go is
/// visible at a glance.
enum StatusLine {
    /// `displayName` is the Models API's name for the model, preferred when there is one (without the
    /// "Claude " the status line already implies, to keep it short).
    static func text(status: String, listening: ListeningState, model: String, displayName: String? = nil) -> String {
        guard listening == .listening else { return status }
        return status + " - " + (displayName.map(ModelName.withoutVendor) ?? ModelName.short(model))
    }
}
