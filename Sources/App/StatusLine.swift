import Foundation

/// The one-line status in the overlay and the menu. The controller's status
/// already names the speech backend ("Listening (on-device)", "(Deepgram)",
/// "(Apple servers)"); while a call is being listened to, this adds the Claude
/// model answers come from, so where audio and transcript text can go is
/// visible at a glance.
enum StatusLine {
    static func text(status: String, listening: ListeningState, model: String) -> String {
        guard listening == .listening else { return status }
        return status + " - " + ModelName.short(model)
    }
}
