import Foundation

/// The overlay window as a list of what the coordinator asked it to do.
@MainActor
final class FakeOverlay: OverlayPresenting {
    private(set) var shows = 0
    private(set) var hides = 0

    /// Whether the overlay is on screen after the calls so far.
    private(set) var isVisible = false

    func show() {
        shows += 1
        isVisible = true
    }

    func hide() {
        hides += 1
        isVisible = false
    }
}

/// The order windows were brought up in, so a test can say which one ended on top.
@MainActor
final class WindowLog {
    private(set) var events: [String] = []

    func record(_ event: String) { events.append(event) }
    func clear() { events = [] }
}

/// The welcome window. `agree()` and `trySample()` play the user's two buttons.
@MainActor
final class FakeWelcome: WelcomePresenting {
    var onTrySample: (() -> Void)?
    var onAgree: (() -> Void)?
    private(set) var shows = 0
    private(set) var closes = 0
    private let log: WindowLog

    init(log: WindowLog) {
        self.log = log
    }

    func show() {
        shows += 1
        log.record("welcome")
    }

    func close() { closes += 1 }

    func agree() { onAgree?() }
    func trySample() { onTrySample?() }
}

@MainActor
final class FakeSummaryWindow: SummaryPresenting {
    private(set) var shows = 0
    private let log: WindowLog

    init(log: WindowLog) {
        self.log = log
    }

    func show() {
        shows += 1
        log.record("summary")
    }
}

@MainActor
final class FakeClipboard: ClipboardWriting {
    private(set) var copies: [String] = []

    func copy(_ text: String) { copies.append(text) }
}

/// The save and folder panels, and Finder. Each panel answers with what the test
/// set up, which is nil when the user cancels, and remembers how it was asked.
@MainActor
final class FakeDialogs: TranscriptDialogs {
    var fileChoice: URL?
    var folderChoice: URL?
    private(set) var fileRequests: [(suggestedName: String, folder: URL)] = []
    private(set) var folderRequests: [URL] = []
    private(set) var revealedFolders: [URL] = []

    func revealInFinder(_ folder: URL) {
        revealedFolders.append(folder)
    }

    func chooseTranscriptFile(suggestedName: String, startingIn folder: URL) -> URL? {
        fileRequests.append((suggestedName, folder))
        return fileChoice
    }

    func chooseTranscriptFolder(startingAt folder: URL) -> URL? {
        folderRequests.append(folder)
        return folderChoice
    }
}
