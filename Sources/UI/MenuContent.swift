import SwiftUI

/// The menu bar icon, which switches to a record symbol while listening.
struct MenuBarIcon: View {
    let controller: AssistantController

    var body: some View {
        Image(systemName: MenuBarSymbol.name(for: controller.listening))
            .accessibilityLabel("Meeting Assistant")
    }
}

/// The menu bar menu. Titles and enabled states come from `MenuState`, and
/// every action goes through the coordinator; this only lays them out.
struct MenuContent: View {
    let coordinator: AppCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject var hotKeys: HotKeyBinder
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let menu = coordinator.menu

        Text(menu.statusLine)
        Divider()

        Button(menu.listeningTitle) { coordinator.toggleListening() }
        Button(menu.answerNowTitle) { coordinator.answerNow() }
        Button(menu.overlayTitle) { coordinator.toggleOverlay() }
        Button("Try a Sample Meeting") { coordinator.trySample() }
            .disabled(!menu.canTrySample)

        Divider()

        Toggle("Auto-answer their questions", isOn: $settings.autoAnswer)
        Picker("Profile", selection: $settings.profile) {
            ForEach(Profile.allCases) { Text($0.rawValue).tag($0) }
        }

        Divider()

        Button("Copy Answer") { coordinator.copyAnswer() }
            .disabled(!menu.canCopyAnswer)
        Button("Copy Transcript") { coordinator.copyTranscript() }
            .disabled(!menu.canCopyTranscript)
        Button("Save Transcript…") { coordinator.saveTranscript() }
            .disabled(!menu.canSaveTranscript)
        Button("Show Transcripts Folder") { coordinator.showTranscriptsFolder() }
        Button("Summarize Meeting") { coordinator.summarizeMeeting() }
            .disabled(!menu.canSummarize)
        Button("Copy Summary") { coordinator.copySummary() }
            .disabled(!menu.canCopySummary)
        Button("Clear Transcript") { coordinator.clearTranscript() }
            .disabled(!menu.canClearTranscript)

        Divider()

        ForEach(menu.privacyFixes, id: \.self) { pane in
            Button("Open \(pane.title) Settings…") { NSWorkspace.shared.open(pane.settingsURL) }
        }
        ForEach(menu.notes, id: \.self) { note in
            Text(note)
        }
        Button("Welcome & Privacy…") { coordinator.showWelcome() }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
