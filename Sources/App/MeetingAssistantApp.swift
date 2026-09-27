import AppKit
import Combine
import SwiftUI

@main
struct MeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Meeting Assistant", systemImage: "waveform.circle") {
            MenuContent(controller: appDelegate.controller, settings: appDelegate.settings,
                        hotKeys: appDelegate.hotKeys, toggleOverlay: appDelegate.toggleOverlay)
        }
        Settings {
            SettingsView(settings: appDelegate.settings, hotKeys: appDelegate.hotKeys)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    let hotKeys = HotKeyBinder()
    private(set) lazy var controller = AssistantController.live(settings: settings)
    private var panel: OverlayPanel?
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let overlay = OverlayView(controller: controller, settings: settings) { [weak self] in
            self?.toggleOverlay()
        }
        let panel = OverlayPanel(contentView: FirstClickHostingView(rootView: overlay))
        if !panel.restoredSavedFrame { positionTopRight(panel) }
        if settings.showsOverlay { panel.orderFrontRegardless() }
        self.panel = panel

        settings.$answerHotKey.combineLatest(settings.$overlayHotKey)
            .sink { [weak self] answer, overlay in self?.bindHotKeys(answer: answer, overlay: overlay) }
            .store(in: &subscriptions)
    }

    func toggleOverlay() {
        guard let panel else { return }
        settings.showsOverlay.toggle()
        if settings.showsOverlay {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func bindHotKeys(answer: HotKeyCombo, overlay: HotKeyCombo) {
        hotKeys.bind(answer: answer, overlay: overlay,
                     onAnswer: { [weak self] in self?.controller.answerNow() },
                     onOverlay: { [weak self] in self?.toggleOverlay() })
    }

    private func positionTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 20
        let frame = panel.frame
        let x = screen.visibleFrame.maxX - frame.width - margin
        let y = screen.visibleFrame.maxY - frame.height - margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct MenuContent: View {
    let controller: AssistantController
    @ObservedObject var settings: AppSettings
    @ObservedObject var hotKeys: HotKeyBinder
    let toggleOverlay: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(controller.isListening ? "Stop Listening" : "Start Listening") {
            controller.toggleListening()
        }
        Button("Answer Now (\(settings.answerHotKey.label))") { controller.answerNow() }
        Button("\(settings.showsOverlay ? "Hide" : "Show") Overlay (\(settings.overlayHotKey.label))") {
            toggleOverlay()
        }

        Divider()

        Toggle("Auto-answer their questions", isOn: $settings.autoAnswer)
        Picker("Profile", selection: $settings.profile) {
            ForEach(Profile.allCases) { Text($0.rawValue).tag($0) }
        }

        Divider()

        Button("Copy Answer") { Clipboard.copy(controller.answer) }
            .disabled(controller.answer.isEmpty)
        Button("Copy Transcript") { Clipboard.copy(controller.transcriptText) }
            .disabled(controller.transcriptDisplay.isEmpty)
        Button("Clear Transcript") { controller.clearTranscript() }

        Divider()

        ForEach(controller.problems.compactMap(\.fix), id: \.self) { pane in
            Button("Open \(pane.title) Settings…") { NSWorkspace.shared.open(pane.settingsURL) }
        }
        if let problem = hotKeys.problem {
            Text(problem)
        }
        if !settings.apiKeyPresent {
            Text("Add your API key in Settings")
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
