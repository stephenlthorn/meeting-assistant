import Foundation

/// Something the user should know about, with the System Settings pane that
/// fixes it when there is one.
struct Problem: Equatable, Identifiable {
    let message: String
    var fix: PrivacyPane?

    var id: String { message }
}

enum PrivacyPane: Hashable, CaseIterable {
    case screenRecording, microphone, speechRecognition

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .speechRecognition: "Speech Recognition"
        }
    }

    var settingsURL: URL {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}
