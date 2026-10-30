import XCTest

/// Whether files saved in a folder would be uploaded to iCloud. The disk is the system boundary, so most
/// cases give the check a made-up home folder and say which paths exist and which macOS calls ubiquitous;
/// the last ones run it against real folders.
final class ICloudFolderCheckTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/ma-test-user", isDirectory: true)

    private func url(_ path: String) -> URL { URL(fileURLWithPath: home.path + "/" + path, isDirectory: true) }

    private func check(existing: [String] = [], ubiquitous: [String] = []) -> ICloudFolderCheck {
        let existing = Set(existing.map { url($0).path })
        let ubiquitous = Set(ubiquitous.map { url($0).path })
        return ICloudFolderCheck(home: home, exists: { existing.contains($0.path) }, isUbiquitous: { ubiquitous.contains($0.path) })
    }

    private let iCloudDrive = "Library/Mobile Documents/com~apple~CloudDocs"

    // MARK: - Folders that stay on the Mac

    func testTheDefaultFolderDoesNotSync() {
        let everythingICloudHas = check(existing: ["\(iCloudDrive)/Desktop", "\(iCloudDrive)/Documents"])

        XCTAssertFalse(everythingICloudHas.syncs(AppSettings.defaultTranscriptFolder(home: home)))
    }

    func testOrdinaryFoldersAndOtherVolumesDoNotSync() {
        let subject = check(existing: ["\(iCloudDrive)/Desktop", "\(iCloudDrive)/Documents"])

        XCTAssertFalse(subject.syncs(url("Notes/Calls")))
        XCTAssertFalse(subject.syncs(URL(fileURLWithPath: "/Volumes/Work/Calls", isDirectory: true)))
    }

    func testAFolderWhoseNameOnlyStartsLikeASyncedOneIsNotInsideIt() {
        let subject = check(existing: ["\(iCloudDrive)/Documents"])

        XCTAssertFalse(subject.syncs(url("Documents2/Calls")))
        XCTAssertFalse(subject.syncs(url("Library/Mobile Documents2/Calls")))
    }

    // MARK: - iCloud Drive

    func testAFolderInICloudDriveSyncsEvenBeforeItExists() {
        XCTAssertTrue(check().syncs(url("\(iCloudDrive)/Calls")))
    }

    func testAnythingUnderMobileDocumentsSyncs() {
        XCTAssertTrue(check().syncs(url("Library/Mobile Documents")))
        XCTAssertTrue(check().syncs(url("Library/Mobile Documents/iCloud~com~example~app/Documents/Calls")))
    }

    func testAFolderMacOSCallsUbiquitousSyncs() {
        let subject = check(existing: ["Work/Calls"], ubiquitous: ["Work/Calls"])

        XCTAssertTrue(subject.syncs(url("Work/Calls")))
    }

    func testAFolderThatDoesNotExistYetFollowsItsNearestExistingParent() {
        let synced = check(existing: ["Work"], ubiquitous: ["Work"])
        let local = check(existing: ["Work"])

        XCTAssertTrue(synced.syncs(url("Work/Calls/2026")))
        XCTAssertFalse(local.syncs(url("Work/Calls/2026")))
    }

    // MARK: - Desktop & Documents

    func testDocumentsSyncsWhenDesktopAndDocumentsSyncIsOn() {
        let subject = check(existing: ["\(iCloudDrive)/Documents"])

        XCTAssertTrue(subject.syncs(url("Documents/Meeting Assistant")))
        XCTAssertTrue(subject.syncs(url("Documents")))
    }

    func testDesktopSyncsWhenItsICloudCopyExists() {
        let subject = check(existing: ["\(iCloudDrive)/Desktop"])

        XCTAssertTrue(subject.syncs(url("Desktop/Calls")))
    }

    func testDocumentsIsLocalWithoutItsICloudCopy() {
        XCTAssertFalse(check().syncs(url("Documents/Meeting Assistant")))
        XCTAssertFalse(check().syncs(url("Desktop/Calls")))
    }

    func testOnlyTheFolderWhoseICloudCopyExistsCountsAsSynced() {
        let subject = check(existing: ["\(iCloudDrive)/Desktop"])

        XCTAssertFalse(subject.syncs(url("Documents/Meeting Assistant")))
    }

    func testAnyOtherFolderInTheHomeIsLocalEvenWithDesktopAndDocumentsSyncOn() {
        let subject = check(existing: ["\(iCloudDrive)/Desktop", "\(iCloudDrive)/Documents"])

        XCTAssertFalse(subject.syncs(url("Movies/Calls")))
    }

    // MARK: - Against the real disk

    func testASymlinkIntoICloudDriveIsFollowed() throws {
        let realHome = try makeHome()
        let drive = realHome.appendingPathComponent(iCloudDrive, isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let link = realHome.appendingPathComponent("Notes")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: drive)

        XCTAssertTrue(ICloudFolderCheck.onDisk(home: realHome).syncs(link.appendingPathComponent("Calls", isDirectory: true)))
    }

    func testAnOrdinaryFolderOnDiskDoesNotSync() throws {
        let realHome = try makeHome()
        let folder = realHome.appendingPathComponent("Library/Application Support/Meeting Assistant/Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertFalse(ICloudFolderCheck.onDisk(home: realHome).syncs(folder))
        XCTAssertFalse(ICloudFolderCheck.onDisk(home: realHome).syncs(folder.appendingPathComponent("not-yet", isDirectory: true)))
    }

    func testRealDocumentsSyncsOnceItsICloudCopyIsOnDisk() throws {
        let realHome = try makeHome()
        try FileManager.default.createDirectory(at: realHome.appendingPathComponent("Documents/Meeting Assistant"), withIntermediateDirectories: true)
        let subject = ICloudFolderCheck.onDisk(home: realHome)
        let folder = realHome.appendingPathComponent("Documents/Meeting Assistant", isDirectory: true)
        XCTAssertFalse(subject.syncs(folder))

        try FileManager.default.createDirectory(at: realHome.appendingPathComponent("\(iCloudDrive)/Documents"), withIntermediateDirectories: true)

        XCTAssertTrue(subject.syncs(folder))
    }

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ICloudFolderCheckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
