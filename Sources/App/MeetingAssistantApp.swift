import AppKit
import Combine
import SwiftUI

@main
struct MeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller, settings: appDelegate.settings,
                        hotKeys: appDelegate.hotKeys, toggleOverlay: appDelegate.toggleOverlay,
                        trySample: appDelegate.trySample, showWelcome: { appDelegate.showWelcome() })
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        Settings {
            SettingsView(settings: appDelegate.settings, hotKeys: appDelegate.hotKeys,
                         showWelcome: { appDelegate.showWelcome() }, withdrawTerms: appDelegate.withdrawTerms)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    let hotKeys = HotKeyBinder()
    private(set) lazy var controller = AssistantController.live(settings: settings)
    private var panel: OverlayPanel?
    private var welcomeWindow: NSWindow?
    private var afterTerms: (() -> Void)?
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let overlay = OverlayView(controller: controller, settings: settings) { [weak self] in
            self?.toggleOverlay()
        }
        let panel = OverlayPanel(contentView: FirstClickHostingView(rootView: overlay))
        if !panel.restoredSavedFrame { positionTopRight(panel) }
        if settings.showsOverlay { panel.orderFrontRegardless() }
        self.panel = panel

        controller.onTermsNeeded = { [weak self] resume in self?.showWelcome(then: resume) }
        if !settings.hasAcceptedTerms { showWelcome() }

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

    func trySample() {
        welcomeWindow?.close()
        if !settings.showsOverlay { toggleOverlay() }
        controller.startSample()
    }

    /// Shows the welcome screen; `resume` runs once the terms are accepted.
    func showWelcome(then resume: (() -> Void)? = nil) {
        afterTerms = resume
        if welcomeWindow == nil {
            let welcome = WelcomeView(onTrySample: { [weak self] in self?.trySample() },
                                      onAgree: { [weak self] in self?.acceptTerms() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: welcome))
            window.title = "Welcome to Meeting Assistant"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            welcomeWindow = window
        }
        NSApp.activate()
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    func withdrawTerms() {
        controller.stop()
        settings.withdrawTerms()
    }

    private func acceptTerms() {
        settings.acceptTerms()
        welcomeWindow?.close()
        let resume = afterTerms
        afterTerms = nil
        resume?()
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

/// The menu bar icon, which switches to a record symbol while listening.
struct MenuBarIcon: View {
    let controller: AssistantController

    var body: some View {
        Image(systemName: MenuBarSymbol.name(for: controller.listening))
            .accessibilityLabel("Meeting Assistant")
    }
}

struct MenuContent: View {
    let controller: AssistantController
    @ObservedObject var settings: AppSettings
    @ObservedObject var hotKeys: HotKeyBinder
    let toggleOverlay: () -> Void
    let trySample: () -> Void
    let showWelcome: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(listeningTitle) { controller.toggleListening() }
        Button("Answer Now (\(settings.answerHotKey.label))") { controller.answerNow() }
        Button("\(settings.showsOverlay ? "Hide" : "Show") Overlay (\(settings.overlayHotKey.label))") {
            toggleOverlay()
        }
        Button("Try a Sample Meeting") { trySample() }
            .disabled(controller.isListening)

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
        Button("Welcome & Privacy…") { showWelcome() }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }

    private var listeningTitle: String {
        switch controller.listening {
        case .idle: "Start Listening"
        case .starting, .listening: "Stop Listening"
        case .sample: "Stop Sample Meeting"
        }
    }
}
