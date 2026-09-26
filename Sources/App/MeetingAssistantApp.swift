import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct MeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Meeting Assistant", systemImage: "waveform.circle") {
            MenuContent(controller: appDelegate.controller)
        }
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AssistantController.live()
    private var panel: OverlayPanel?
    private var answerHotKey: HotKeyManager?
    private var toggleHotKey: HotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingView(rootView: OverlayView(controller: controller))
        let panel = OverlayPanel(contentView: hosting)
        positionTopRight(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        // ⌘⇧Space: ask the model for help now.
        answerHotKey = try? HotKeyManager(combo: HotKeyCombo(keyCode: UInt32(kVK_Space),
                                                             modifiers: UInt32(cmdKey | shiftKey),
                                                             label: "⌘⇧Space")) { [weak self] in
            self?.controller.answerNow()
        }
        // ⌘⇧H: show/hide the overlay.
        toggleHotKey = try? HotKeyManager(combo: HotKeyCombo(keyCode: UInt32(kVK_ANSI_H),
                                                             modifiers: UInt32(cmdKey | shiftKey),
                                                             label: "⌘⇧H")) { [weak self] in
            self?.toggleOverlay()
        }
    }

    private func toggleOverlay() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
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
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Button(controller.isListening ? "Stop Listening" : "Start Listening") {
            controller.toggleListening()
        }
        Button("Answer Now (⌘⇧Space)") { controller.answerNow() }

        Divider()

        Toggle("Auto-answer their questions", isOn: $settings.autoAnswer)
        Picker("Profile", selection: $settings.profile) {
            ForEach(Profile.allCases) { Text($0.rawValue).tag($0) }
        }

        Divider()

        Button("Copy Transcript") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(controller.transcriptText, forType: .string)
        }
        .disabled(controller.transcriptText.isEmpty)
        Button("Clear Transcript") { controller.clearTranscript() }

        Divider()

        SettingsLink { Text("Settings…") }
        if !settings.apiKeyPresent {
            Text("Set your API key in Settings")
        }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
