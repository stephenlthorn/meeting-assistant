import Foundation

/// An app whose audio can be captured on its own.
struct MeetingApp: Equatable, Identifiable, Sendable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}

/// The apps calls usually happen in, for the "listen to this app only" choice.
/// Browsers are here because Meet, Teams and Zoom run in them.
enum MeetingApps {
    static let known: [MeetingApp] = [
        MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
        MeetingApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
        MeetingApp(bundleID: "com.microsoft.teams", name: "Microsoft Teams (classic)"),
        MeetingApp(bundleID: "Cisco-Systems.Spark", name: "Webex"),
        MeetingApp(bundleID: "com.apple.FaceTime", name: "FaceTime"),
        MeetingApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        MeetingApp(bundleID: "com.google.Chrome", name: "Google Chrome"),
        MeetingApp(bundleID: "com.apple.Safari", name: "Safari"),
        MeetingApp(bundleID: "company.thebrowser.Browser", name: "Arc"),
        MeetingApp(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge"),
        MeetingApp(bundleID: "org.mozilla.firefox", name: "Firefox"),
    ]

    static func name(for bundleID: String) -> String? {
        known.first { $0.bundleID == bundleID }?.name
    }

    /// What the picker offers besides "All apps": the known apps that are running,
    /// plus the saved choice even when it is not running (or not on the list at
    /// all), so the picker never shows a selection it cannot name.
    static func choices(running: Set<String>, saved: String?) -> [MeetingApp] {
        var apps = known.filter { running.contains($0.bundleID) || $0.bundleID == saved }
        if let saved, !apps.contains(where: { $0.bundleID == saved }) {
            apps.append(MeetingApp(bundleID: saved, name: saved))
        }
        return apps
    }

    static func label(for app: MeetingApp, running: Set<String>) -> String {
        running.contains(app.bundleID) ? app.name : "\(app.name) (not running)"
    }
}
