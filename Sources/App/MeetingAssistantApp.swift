import AppKit
import SwiftUI

@main
struct MeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: appDelegate.coordinator, settings: appDelegate.settings,
                        hotKeys: appDelegate.hotKeys)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        Settings {
            SettingsView(settings: appDelegate.settings, hotKeys: appDelegate.hotKeys,
                         showWelcome: { appDelegate.coordinator.showWelcome() },
                         withdrawTerms: { appDelegate.coordinator.withdrawTerms() },
                         chooseTranscriptFolder: { appDelegate.coordinator.chooseTranscriptFolder() },
                         showTranscriptsFolder: { appDelegate.coordinator.showTranscriptsFolder() })
        }
    }
}

/// Wires the real pieces to `AppCoordinator`; everything it decides is in there.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    let hotKeys = HotKeyBinder()
    private(set) lazy var controller = AssistantController.live(settings: settings)
    private(set) lazy var coordinator: AppCoordinator = AppCoordinator(
        settings: settings, controller: controller, hotKeys: hotKeys,
        overlay: OverlayWindow { [unowned self] in
            FirstClickHostingView(rootView: OverlayView(controller: controller, settings: settings) { [weak self] in
                self?.coordinator.toggleOverlay()
            })
        },
        welcome: WelcomeWindow(),
        summary: SummaryWindow(controller: controller),
        dialogs: AppKitTranscriptDialogs(),
        clipboard: SystemClipboard())

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.willTerminate()
    }
}
